#!/usr/bin/env bash
# Applies the branch protection of `main` documented in docs/branch-protection.md.
#
#   scripts/apply-branch-protection.sh [clinical|imaging|infra|all] [--dry-run]
#
# Idempotent (PUT replaces the whole protection). Requires `gh` authenticated as a repository
# admin. Required check names must exist on open PRs before tightening them, otherwise those PRs
# stay blocked waiting for a check that never reports (see "Rollout" in the doc).
set -euo pipefail

ORG="OnControl3D-ASF"
TARGET="${1:-all}"
DRY_RUN="${2:-}"

# Required status checks per repository (job names as reported by GitHub Actions).
CLINICAL_CHECKS='"Build, test & quality gate","Validate Kubernetes manifests","SAST (Semgrep)","Dependency scan (Trivy)","Secret scan (gitleaks)","Image scan (Trivy)"'
IMAGING_CHECKS='"Build, lint & test","Validate Kubernetes manifests","SAST (Semgrep)","Dependency scan (Trivy)","Secret scan (gitleaks)","Image scan (Trivy)"'
# IaC and third-party image scans are path-filtered: requiring them would block unrelated PRs.
INFRA_CHECKS='"gitleaks"'

payload() {
  cat <<EOF
{
  "required_status_checks": { "strict": false, "contexts": [$1] },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "require_last_push_approval": true
  },
  "required_conversation_resolution": true,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "restrictions": null
}
EOF
}

apply() {
  local repo="$1" checks="$2"
  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "== $repo (dry run)"; payload "$checks"; return
  fi
  payload "$checks" | gh api -X PUT "repos/$ORG/$repo/branches/main/protection" --input - \
    --jq '"\(.url | split("/")[5]): approvals=\(.required_pull_request_reviews.required_approving_review_count) codeowners=\(.required_pull_request_reviews.require_code_owner_reviews) last-push=\(.required_pull_request_reviews.require_last_push_approval) admins=\(.enforce_admins.enabled) checks=[\(.required_status_checks.contexts | join(", "))]"'
}

case "$TARGET" in
  clinical) apply oncontrol3d-backend-clinical "$CLINICAL_CHECKS" ;;
  imaging)  apply oncontrol3d-imaging-service "$IMAGING_CHECKS" ;;
  infra)    apply oncontrol3d-infra "$INFRA_CHECKS" ;;
  all)
    apply oncontrol3d-backend-clinical "$CLINICAL_CHECKS"
    apply oncontrol3d-imaging-service "$IMAGING_CHECKS"
    apply oncontrol3d-infra "$INFRA_CHECKS"
    ;;
  *) echo "usage: $0 [clinical|imaging|infra|all] [--dry-run]" >&2; exit 2 ;;
esac
