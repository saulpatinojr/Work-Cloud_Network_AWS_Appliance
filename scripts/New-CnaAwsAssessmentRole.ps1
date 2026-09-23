<#
.SYNOPSIS
Creates the read-only AWS role the CNA app's "Add Cloud Connection" form asks
for — in the management account and, optionally, in every account of the
organization — and emits everything the form needs.

.DESCRIPTION
The AWS counterpart of the Azure appliance's New-CnaAssessmentServicePrincipal.ps1.
Discovery signs in to the management account with the access key entered on
the form, lists the organization's accounts, and assumes a role of the SAME
NAME in each one (the name is taken from the role ARN on the form), passing the
external ID. This script builds exactly that shape:

  1. The scanner role in the current (management) account, trusting one
     principal — the scanner principal — with an sts:ExternalId condition and
     the three managed policies the platform's reader roles carry:
     ReadOnlyAccess, SecurityAudit, AWSBillingReadOnlyAccess.
  2. With -OrganizationWide: a CloudFormation StackSet (service-managed
     permissions, auto-deployment on) that creates the identical role in every
     member account under the given organizational units, so new accounts are
     covered as they join.
  3. With -CreateScannerUser: the scanner principal itself — an IAM user whose
     only permissions are to assume the scanner role, list the organization's
     accounts and enumerate regions — plus one access key, shown once. The
     form needs an access key because the API container has no ambient AWS
     credential chain; a long-lived key is the trade-off, so rotate it (re-run
     the script) and delete the user when the engagement ends.

Idempotent: re-running reuses the role, StackSet and user, refreshes the trust
policy and, unless -SkipAccessKey, mints a fresh access key.

Secrets policy: the secret access key is printed ONCE to the console and is
never written to disk or to the report. The external ID is not a credential
but is treated like one: shown once, never stored by this script.

.PARAMETER RoleName
Name of the scanner role in every account. Must be identical everywhere —
discovery derives it from the ARN on the form.

.PARAMETER ScannerPrincipalArn
ARN of the IAM principal (in the management account) that will assume the
scanner role. Required unless -CreateScannerUser.

.PARAMETER ExternalId
External ID for the assume-role condition. Generated when omitted.

.PARAMETER CreateScannerUser
Create (or reuse) the IAM user named by -ScannerUserName as the scanner
principal and mint an access key for the form.

.PARAMETER ScannerUserName
IAM user name used with -CreateScannerUser.

.PARAMETER SkipAccessKey
With -CreateScannerUser: do not mint a new access key (re-runs that only
extend the role to more accounts).

.PARAMETER OrganizationWide
Also deploy the role to every member account through a service-managed
CloudFormation StackSet. Requires running from the organization's management
account (or a delegated administrator) with trusted access for StackSets.

.PARAMETER OrganizationalUnitIds
OU ids the StackSet targets. Defaults to the organization root, i.e. every
account.

.PARAMETER AwsProfile
Named AWS CLI profile to use instead of the default credential chain.

.PARAMETER Region
Region for the StackSet's administration and API calls (IAM is global).

.PARAMETER ReportDirectory
Where the JSON run report is written (gitignored). Contains ARNs and account
ids only — never the external ID or a key.

.EXAMPLE
# Management account only; you bring the scanner principal:
./scripts/New-CnaAwsAssessmentRole.ps1 -ScannerPrincipalArn arn:aws:iam::111111111111:user/cna-scanner

.EXAMPLE
# Whole organization, and create the scanner user + access key for the form:
./scripts/New-CnaAwsAssessmentRole.ps1 -CreateScannerUser -OrganizationWide

.EXAMPLE
# Extend to new OUs later without rotating the key:
./scripts/New-CnaAwsAssessmentRole.ps1 -CreateScannerUser -SkipAccessKey -OrganizationWide -OrganizationalUnitIds ou-abcd-11111111
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RoleName = "CNA-Assessment-Scanner",

    [string]$ScannerPrincipalArn = "",

    [string]$ExternalId = "",

    [switch]$CreateScannerUser,

    [string]$ScannerUserName = "cna-assessment-scanner",

    [switch]$SkipAccessKey,

    [switch]$OrganizationWide,

    [string[]]$OrganizationalUnitIds = @(),

    [string]$AwsProfile = "",

    [string]$Region = "us-east-1",

    [string]$ReportDirectory = ".reports/assessment"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step { param([string]$Message) Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [!] $Message" -ForegroundColor Yellow }

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name CLI not found. Install it and rerun this script."
    }
}

function Invoke-Aws {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$NoOutput
    )
    $args = @($Arguments) + @("--region", $Region, "--output", "json")
    if (-not [string]::IsNullOrWhiteSpace($AwsProfile)) { $args += @("--profile", $AwsProfile) }
    $raw = & aws @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "aws $($Arguments -join ' ') failed: $raw"
    }
    if ($NoOutput -or [string]::IsNullOrWhiteSpace(($raw | Out-String))) { return $null }
    return (($raw | Out-String) | ConvertFrom-Json)
}

function Write-TempJson {
    param([object]$Document)
    $path = [System.IO.Path]::GetTempFileName()
    $Document | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    return $path
}

function New-ExternalId {
    # 32 URL-safe characters from a CSPRNG; sts:ExternalId allows [\w+=,.@:/-].
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([Convert]::ToBase64String($bytes)).Replace("+", "-").Replace("/", "_").TrimEnd("=")
}

function Confirm-ManagedPolicyAttachments {
    param([string]$Role, [string]$Partition)
    foreach ($policyName in @("ReadOnlyAccess", "SecurityAudit", "AWSBillingReadOnlyAccess")) {
        $policyArn = "arn:${Partition}:iam::aws:policy/$policyName"
        $attached = Invoke-Aws -Arguments @("iam", "list-attached-role-policies", "--role-name", $Role)
        if (@($attached.AttachedPolicies | Where-Object { $_.PolicyArn -eq $policyArn }).Count -gt 0) {
            Write-Ok "Attached already: $policyName"
            continue
        }
        if ($PSCmdlet.ShouldProcess($Role, "attach $policyName")) {
            Invoke-Aws -Arguments @("iam", "attach-role-policy", "--role-name", $Role, "--policy-arn", $policyArn) -NoOutput | Out-Null
        }
        Write-Ok "Attached: $policyName"
    }
}

# ─── Preflight ────────────────────────────────────────────────────────────────
Write-Step "Checking prerequisites"
Assert-Command aws
$identity = Invoke-Aws -Arguments @("sts", "get-caller-identity")
$accountId = [string]$identity.Account
$partition = ([string]$identity.Arn).Split(":")[1]
Write-Ok "AWS account $accountId ($partition), caller $($identity.Arn)"

if (-not $CreateScannerUser -and [string]::IsNullOrWhiteSpace($ScannerPrincipalArn)) {
    throw "Pass -ScannerPrincipalArn (the principal that will assume $RoleName) or -CreateScannerUser."
}

$externalIdGenerated = $false
if ([string]::IsNullOrWhiteSpace($ExternalId)) {
    $ExternalId = New-ExternalId
    $externalIdGenerated = $true
}

# ─── 1. Scanner principal (optional) ──────────────────────────────────────────
$accessKeyId = $null
$secretAccessKey = $null
if ($CreateScannerUser) {
    Write-Step "Ensuring scanner IAM user $ScannerUserName"
    $user = Invoke-Aws -Arguments @("iam", "get-user", "--user-name", $ScannerUserName) -AllowFailure
    if ($user) {
        Write-Ok "User exists"
    } else {
        if ($PSCmdlet.ShouldProcess($ScannerUserName, "create IAM user")) {
            $user = Invoke-Aws -Arguments @("iam", "create-user", "--user-name", $ScannerUserName, "--tags", "Key=Project,Value=cna", "Key=Purpose,Value=assessment-scanner")
        }
        Write-Ok "Created user"
    }
    $ScannerPrincipalArn = "arn:${partition}:iam::${accountId}:user/${ScannerUserName}"

    # The user can do three things: assume the scanner role anywhere in the
    # organization, list the accounts to assume it in, and enumerate regions
    # (discovery calls DescribeRegions before it knows the region list).
    $userPolicy = [ordered]@{
        Version   = "2012-10-17"
        Statement = @(
            [ordered]@{
                Sid      = "AssumeScannerRole"
                Effect   = "Allow"
                Action   = @("sts:AssumeRole")
                Resource = @("arn:${partition}:iam::*:role/${RoleName}")
            },
            [ordered]@{
                Sid      = "EnumerateOrganizationAndRegions"
                Effect   = "Allow"
                Action   = @("organizations:ListAccounts", "organizations:DescribeOrganization", "sts:GetCallerIdentity", "ec2:DescribeRegions")
                Resource = @("*")
            }
        )
    }
    $userPolicyFile = Write-TempJson -Document $userPolicy
    try {
        if ($PSCmdlet.ShouldProcess($ScannerUserName, "put inline policy cna-assessment-scanner")) {
            Invoke-Aws -Arguments @("iam", "put-user-policy", "--user-name", $ScannerUserName, "--policy-name", "cna-assessment-scanner", "--policy-document", "file://$userPolicyFile") -NoOutput | Out-Null
        }
        Write-Ok "Inline policy in place (assume $RoleName, list accounts, describe regions)"
    } finally {
        Remove-Item -Path $userPolicyFile -Force -ErrorAction SilentlyContinue
    }

    if ($SkipAccessKey) {
        Write-Ok "Skipping access key (-SkipAccessKey): the key already saved in the app's connection keeps working."
    } else {
        $keys = Invoke-Aws -Arguments @("iam", "list-access-keys", "--user-name", $ScannerUserName)
        if (@($keys.AccessKeyMetadata).Count -ge 2) {
            throw "$ScannerUserName already has two access keys (the IAM maximum). Delete the one no longer in use with 'aws iam delete-access-key' and re-run, or pass -SkipAccessKey."
        }
        if ($PSCmdlet.ShouldProcess($ScannerUserName, "create access key")) {
            $created = Invoke-Aws -Arguments @("iam", "create-access-key", "--user-name", $ScannerUserName)
            $accessKeyId = [string]$created.AccessKey.AccessKeyId
            $secretAccessKey = [string]$created.AccessKey.SecretAccessKey
        }
        Write-Ok "Minted a new access key (shown once below)"
        if (@($keys.AccessKeyMetadata).Count -eq 1) {
            Write-Warn "The user's previous key $($keys.AccessKeyMetadata[0].AccessKeyId) is still active. Delete it once the app's connection has been updated."
        }
    }
}

# ─── 2. Scanner role in this (management) account ─────────────────────────────
Write-Step "Ensuring scanner role $RoleName in account $accountId"
$trustPolicy = [ordered]@{
    Version   = "2012-10-17"
    Statement = @(
        [ordered]@{
            Sid       = "CnaScannerAssume"
            Effect    = "Allow"
            Principal = @{ AWS = $ScannerPrincipalArn }
            Action    = "sts:AssumeRole"
            Condition = @{ StringEquals = @{ "sts:ExternalId" = $ExternalId } }
        }
    )
}
$trustFile = Write-TempJson -Document $trustPolicy
try {
    $role = Invoke-Aws -Arguments @("iam", "get-role", "--role-name", $RoleName) -AllowFailure
    if ($role) {
        if ($PSCmdlet.ShouldProcess($RoleName, "update trust policy")) {
            Invoke-Aws -Arguments @("iam", "update-assume-role-policy", "--role-name", $RoleName, "--policy-document", "file://$trustFile") -NoOutput | Out-Null
        }
        Write-Ok "Role exists; trust policy refreshed for $ScannerPrincipalArn"
    } else {
        if ($PSCmdlet.ShouldProcess($RoleName, "create role")) {
            Invoke-Aws -Arguments @(
                "iam", "create-role",
                "--role-name", $RoleName,
                "--assume-role-policy-document", "file://$trustFile",
                "--description", "Read-only role assumed by the CNA assessment scanner",
                "--max-session-duration", "3600",
                "--tags", "Key=Project,Value=cna", "Key=Purpose,Value=assessment-scanner"
            ) | Out-Null
        }
        Write-Ok "Created role"
    }
} finally {
    Remove-Item -Path $trustFile -Force -ErrorAction SilentlyContinue
}
Confirm-ManagedPolicyAttachments -Role $RoleName -Partition $partition
$roleArn = "arn:${partition}:iam::${accountId}:role/${RoleName}"

# ─── 3. Every member account via a StackSet (optional) ────────────────────────
$coveredAccounts = @([pscustomobject]@{ Id = $accountId; Name = "management (this account)" })
$stackSetName = "cna-assessment-scanner-role"
if ($OrganizationWide) {
    Write-Step "Deploying $RoleName to the organization with StackSet $stackSetName"
    $org = Invoke-Aws -Arguments @("organizations", "describe-organization") -AllowFailure
    if (-not $org) {
        throw "This account is not an AWS Organizations management or delegated-administrator account (describe-organization failed). Run per account without -OrganizationWide instead."
    }
    if ([string]$org.Organization.MasterAccountId -ne $accountId) {
        Write-Warn "Account $accountId is not the management account ($($org.Organization.MasterAccountId)). StackSet deployment needs delegated-administrator rights for CloudFormation."
    }

    # Trusted access lets CloudFormation create the execution roles in member
    # accounts itself (service-managed permissions). Idempotent.
    if ($PSCmdlet.ShouldProcess("organization", "enable StackSets trusted access")) {
        Invoke-Aws -Arguments @("organizations", "enable-aws-service-access", "--service-principal", "member.org.stacksets.cloudformation.amazonaws.com") -NoOutput -AllowFailure | Out-Null
    }

    if ($OrganizationalUnitIds.Count -eq 0) {
        $roots = Invoke-Aws -Arguments @("organizations", "list-roots")
        $OrganizationalUnitIds = @($roots.Roots | ForEach-Object { [string]$_.Id })
        Write-Ok "Targeting the organization root: $($OrganizationalUnitIds -join ', ')"
    }

    # Same role, same trust, same three policies — parameterised so the
    # external ID never lives in the template body.
    $template = @"
AWSTemplateFormatVersion: "2010-09-09"
Description: Read-only role assumed by the CNA assessment scanner (deployed by the CNA AWS appliance's New-CnaAwsAssessmentRole.ps1).
Parameters:
  RoleName:
    Type: String
  ScannerPrincipalArn:
    Type: String
  ExternalId:
    Type: String
    NoEcho: true
Resources:
  ScannerRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Ref RoleName
      Description: Read-only role assumed by the CNA assessment scanner
      MaxSessionDuration: 3600
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Sid: CnaScannerAssume
            Effect: Allow
            Principal:
              AWS: !Ref ScannerPrincipalArn
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                sts:ExternalId: !Ref ExternalId
      ManagedPolicyArns:
        - !Sub arn:`${AWS::Partition}:iam::aws:policy/ReadOnlyAccess
        - !Sub arn:`${AWS::Partition}:iam::aws:policy/SecurityAudit
        - !Sub arn:`${AWS::Partition}:iam::aws:policy/AWSBillingReadOnlyAccess
      Tags:
        - Key: Project
          Value: cna
        - Key: Purpose
          Value: assessment-scanner
"@
    $templateFile = [System.IO.Path]::GetTempFileName() + ".yaml"
    Set-Content -Path $templateFile -Value $template -Encoding UTF8
    $parameters = @(
        "ParameterKey=RoleName,ParameterValue=$RoleName",
        "ParameterKey=ScannerPrincipalArn,ParameterValue=$ScannerPrincipalArn",
        "ParameterKey=ExternalId,ParameterValue=$ExternalId"
    )
    try {
        $existing = Invoke-Aws -Arguments @("cloudformation", "describe-stack-set", "--stack-set-name", $stackSetName, "--call-as", "SELF") -AllowFailure
        $operationId = $null
        if ($existing) {
            if ($PSCmdlet.ShouldProcess($stackSetName, "update StackSet")) {
                $op = Invoke-Aws -Arguments (@(
                    "cloudformation", "update-stack-set",
                    "--stack-set-name", $stackSetName,
                    "--template-body", "file://$templateFile",
                    "--parameters") + $parameters + @(
                    "--capabilities", "CAPABILITY_NAMED_IAM",
                    "--permission-model", "SERVICE_MANAGED",
                    "--auto-deployment", "Enabled=true,RetainStacksOnAccountRemoval=false",
                    "--deployment-targets", "OrganizationalUnitIds=$($OrganizationalUnitIds -join ',')",
                    "--regions", $Region,
                    "--operation-preferences", "FailureTolerancePercentage=100,MaxConcurrentPercentage=100"
                ))
                $operationId = [string]$op.OperationId
            }
            Write-Ok "StackSet exists; update submitted"
        } else {
            if ($PSCmdlet.ShouldProcess($stackSetName, "create StackSet")) {
                Invoke-Aws -Arguments (@(
                    "cloudformation", "create-stack-set",
                    "--stack-set-name", $stackSetName,
                    "--description", "CNA assessment scanner read-only role in every member account",
                    "--template-body", "file://$templateFile",
                    "--parameters") + $parameters + @(
                    "--capabilities", "CAPABILITY_NAMED_IAM",
                    "--permission-model", "SERVICE_MANAGED",
                    "--auto-deployment", "Enabled=true,RetainStacksOnAccountRemoval=false",
                    "--tags", "Key=Project,Value=cna"
                )) | Out-Null
                $op = Invoke-Aws -Arguments @(
                    "cloudformation", "create-stack-instances",
                    "--stack-set-name", $stackSetName,
                    "--deployment-targets", "OrganizationalUnitIds=$($OrganizationalUnitIds -join ',')",
                    "--regions", $Region,
                    "--operation-preferences", "FailureTolerancePercentage=100,MaxConcurrentPercentage=100"
                )
                $operationId = [string]$op.OperationId
            }
            Write-Ok "StackSet created; instance creation submitted"
        }

        if ($operationId) {
            Write-Host "    waiting for StackSet operation $operationId ..." -NoNewline
            do {
                Start-Sleep -Seconds 15
                $status = Invoke-Aws -Arguments @("cloudformation", "describe-stack-set-operation", "--stack-set-name", $stackSetName, "--operation-id", $operationId)
                $state = [string]$status.StackSetOperation.Status
                Write-Host "." -NoNewline
            } while ($state -in @("RUNNING", "QUEUED", "STOPPING"))
            Write-Host ""
            if ($state -ne "SUCCEEDED") {
                Write-Warn "StackSet operation finished with status $state. Inspect: aws cloudformation list-stack-set-operation-results --stack-set-name $stackSetName --operation-id $operationId"
            } else {
                Write-Ok "StackSet operation succeeded"
            }
        }
    } finally {
        Remove-Item -Path $templateFile -Force -ErrorAction SilentlyContinue
    }

    $accounts = Invoke-Aws -Arguments @("organizations", "list-accounts")
    $coveredAccounts = @($accounts.Accounts | Where-Object { $_.Status -eq "ACTIVE" } | ForEach-Object {
        [pscustomobject]@{ Id = [string]$_.Id; Name = [string]$_.Name }
    })
    Write-Ok "$($coveredAccounts.Count) active account(s) in the organization"
}

# ─── Output ───────────────────────────────────────────────────────────────────
Write-Step "Values for the Add Cloud Connection form"
Write-Host ""
Write-Host "  Role ARN         : $roleArn" -ForegroundColor White
Write-Host "  External ID      : $ExternalId" -ForegroundColor Yellow
if ($externalIdGenerated) {
    Write-Host "                     (generated now — shown ONCE, not saved anywhere by this script)" -ForegroundColor Yellow
}
if ($CreateScannerUser) {
    Write-Host "  Access Key ID    : $(if ($accessKeyId) { $accessKeyId } else { '(unchanged — -SkipAccessKey)' })" -ForegroundColor White
    if ($secretAccessKey) {
        Write-Host "  Secret Access Key: $secretAccessKey" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  The secret access key is shown ONCE and is not saved anywhere by this script." -ForegroundColor Yellow
        Write-Host "  Paste it into the form now; the app stores it encrypted at rest." -ForegroundColor Yellow
        Write-Host "  It is a long-lived credential: re-run this script to rotate it, and delete the" -ForegroundColor Yellow
        Write-Host "  user ($ScannerUserName) when the engagement ends." -ForegroundColor Yellow
    }
} else {
    Write-Host "  Access key       : mint one for $ScannerPrincipalArn yourself, or re-run with -CreateScannerUser." -ForegroundColor White
}
Write-Host ""
Write-Host "  Accounts covered : $($coveredAccounts.Count)$(if (-not $OrganizationWide) { ' — re-run with -OrganizationWide to cover every member account' })"
Write-Host "  New IAM principals can take a minute to propagate before 'Test connection' passes."

New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$reportPath = Join-Path $ReportDirectory "$((Get-Date).ToString('yyyyMMdd-HHmmss'))-aws-scanner.json"
$reportStackSet = if ($OrganizationWide) { $stackSetName } else { $null }
[ordered]@{
    generated_at          = (Get-Date).ToUniversalTime().ToString("o")
    management_account_id = $accountId
    partition             = $partition
    role_name             = $RoleName
    role_arn              = $roleArn
    scanner_principal_arn = $ScannerPrincipalArn
    access_key_id         = $accessKeyId
    organization_wide     = [bool]$OrganizationWide
    stack_set             = $reportStackSet
    organizational_units  = $OrganizationalUnitIds
    accounts              = $coveredAccounts
} | ConvertTo-Json -Depth 5 | Set-Content -Path $reportPath -Encoding UTF8
Write-Ok "Report written: $reportPath (no external ID, no secret key)"
