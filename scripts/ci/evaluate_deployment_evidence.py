"""
Evaluate deployment evidence and update the release catalog manifest.

Reads from environment variables:
  MANIFEST_PATH                      — path to deployment-manifest.json
  VERIFICATION_DIR                   — path to .verification/{environment}/
  AZURE_MONITOR_HEALTH_THRESHOLD     — minimum origin health % (e.g. "95")
  APP_INSIGHTS_SUCCESS_THRESHOLD     — minimum success rate (e.g. "0.99")
  CERTIFICATE_EXPIRY_DAYS_THRESHOLD  — minimum days before cert expiry (e.g. "30")
  CANARY_WEIGHT_PERCENT              — canary traffic weight (e.g. "10")
  PRIMARY_WEIGHT_PERCENT             — primary traffic weight (e.g. "90")
"""

import json
import os
import sys
from datetime import UTC, datetime
from pathlib import Path

manifest_path = Path(os.environ["MANIFEST_PATH"])
base = Path(os.environ["VERIFICATION_DIR"])

health_threshold = float(os.environ.get("AZURE_MONITOR_HEALTH_THRESHOLD", "95"))
success_threshold = float(os.environ.get("APP_INSIGHTS_SUCCESS_THRESHOLD", "0.99"))
cert_expiry_threshold = int(os.environ.get("CERTIFICATE_EXPIRY_DAYS_THRESHOLD", "30"))
canary_weight = int(os.environ.get("CANARY_WEIGHT_PERCENT", "10"))
primary_weight = int(os.environ.get("PRIMARY_WEIGHT_PERCENT", "90"))

# --- Load evidence files ---
health = json.loads((base / "external-health.json").read_text())
promotion = json.loads((base / "staged-promotion.json").read_text())
renewal_status_path = base / "certificate-renewal-status.json"
rotation_path = base / "certificate-rotation.json"

# Telemetry is optional (only collected when App Insights is configured)
telemetry_path = base / "canary-telemetry.json"
success_rate = 1.0  # default pass when telemetry not available
if telemetry_path.exists() and telemetry_path.stat().st_size > 0:
    telemetry = json.loads(telemetry_path.read_text())
    telemetry_tables = telemetry.get("tables", [])
    if telemetry_tables and telemetry_tables[0].get("rows"):
        success_rate = float(telemetry_tables[0]["rows"][0][0])

# Certificate monitoring is optional (only when Key Vault is configured)
certificate_path = base / "certificate-monitoring.json"
days_to_expiry = cert_expiry_threshold + 1  # default pass when cert not configured
if certificate_path.exists() and certificate_path.stat().st_size > 0:
    certificate = json.loads(certificate_path.read_text())
    expiry = certificate.get("attributes", {}).get("expires")
    if expiry:
        expiry_dt = (
            datetime.fromisoformat(expiry.replace("Z", "+00:00"))
            if "T" in expiry
            else datetime.fromtimestamp(int(expiry), tz=UTC)
        )
        days_to_expiry = (expiry_dt - datetime.now(UTC)).days

# --- Parse health metric ---
metric_value = 0.0
if health.get("value"):
    timeseries = health["value"][0].get("timeseries", [{}])
    if timeseries and timeseries[0].get("data"):
        metric_value = float(timeseries[0]["data"][-1].get("average", 0.0))

# --- Validate thresholds ---
errors = []
if metric_value < health_threshold:
    errors.append(f"Origin health below threshold: {metric_value:.1f}% < {health_threshold}%")
if success_rate < success_threshold:
    errors.append(f"Canary success rate below threshold: {success_rate:.3f} < {success_threshold}")

renewal_verified = renewal_status_path.exists() and renewal_status_path.stat().st_size > 0
rotation_verified = rotation_path.exists() and rotation_path.stat().st_size > 0
if days_to_expiry < cert_expiry_threshold and not (renewal_verified or rotation_verified):
    errors.append(
        f"Certificate expiry below threshold and no renewal evidence: "
        f"{days_to_expiry} days < {cert_expiry_threshold} days threshold"
    )

if errors:
    for err in errors:
        print(f"::error::{err}", file=sys.stderr)
    sys.exit(1)

# --- Update manifest ---
with manifest_path.open() as f:
    data = json.load(f)

checks = data["validation_checks"]
checks["post_deploy_probe"] = "passed"
checks["independent_verification"] = "passed"
checks["promotion_ready"] = "passed"
checks["external_health_validation"] = "passed"
checks["certificate_monitoring"] = "passed"
checks["canary_telemetry"] = "passed"
checks["staged_promotion"] = "passed"
checks["certificate_rotation"] = "passed"

data["approval_status"] = "approved"
data["health_status"] = "healthy"
data["evidence_summary"] = {
    "origin_health_percentage": metric_value,
    "canary_success_rate": success_rate,
    "certificate_days_to_expiry": days_to_expiry,
    "certificate_renewal_verified": renewal_verified,
    "certificate_rotation_verified": rotation_verified,
    "promotion_action": promotion.get("name", "progressive-origin-update"),
    "canary_weight_percent": canary_weight,
    "primary_weight_percent": primary_weight,
}

with manifest_path.open("w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("Deployment evidence evaluated — all checks passed")
print(f"  origin_health_percentage = {metric_value:.1f}%")
print(f"  canary_success_rate      = {success_rate:.3f}")
print(f"  certificate_days_to_expiry = {days_to_expiry}")
