#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat > "$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/actions/runner/releases/latest"* ]]; then
  printf '{"tag_name":"%s"}\n' "${MOCK_LATEST_TAG:-v2.321.0}"
else
  printf '{"token":"runner-token"}\n'
fi
EOF

cat > "$tmp_dir/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GCLOUD_LOG}"
if [[ "$*" == *"compute instances describe"* ]]; then
  printf '{"labels":{"gh_ready":"1"}}\n'
fi
EOF
chmod +x "$tmp_dir/bin/curl" "$tmp_dir/bin/gcloud"

run_action() {
  local runner_ver=$1
  local shutdown_timeout=$2
  local latest_tag=${3:-v2.321.0}
  : > "$tmp_dir/gcloud.log"
  set +e
  output=$(
    PATH="$tmp_dir/bin:$PATH" \
    GCLOUD_LOG="$tmp_dir/gcloud.log" \
    MOCK_LATEST_TAG="$latest_tag" \
    GITHUB_REPOSITORY=example/repo \
    GITHUB_REPOSITORY_OWNER=example \
    GITHUB_RUN_ID=123 \
    GITHUB_RUN_ATTEMPT=1 \
    GITHUB_OUTPUT="$tmp_dir/output" \
    "$repo_root/action.sh" \
      --command=start \
      --token=test-token \
      --project_id= \
      --service_account_key= \
      --runner_ver="$runner_ver" \
      --vm_name_prefix=test-runner \
      --machine_zone=us-east1-c \
      --machine_type=n1-standard-1 \
      --scopes=cloud-platform \
      --shutdown_timeout="$shutdown_timeout" \
      --preemptible=false \
      --ephemeral=false \
      --no_external_address=false \
      --actions_preinstalled=false \
      --arm=false \
      2>&1
  )
  status=$?
  set -e
}

assert_rejected_before_gcloud() {
  local expected_message=$1
  if [[ $status -eq 0 ]]; then
    printf 'expected failure, got success\n%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected_message"* ]]; then
    printf 'missing error %q in output:\n%s\n' "$expected_message" "$output" >&2
    exit 1
  fi
  if [[ -s "$tmp_dir/gcloud.log" ]]; then
    printf 'gcloud ran for rejected input:\n' >&2
    cat "$tmp_dir/gcloud.log" >&2
    exit 1
  fi
}

run_action '2.321.0; touch /tmp/runner-version-marker' 30
assert_rejected_before_gcloud 'Invalid runner_ver'

run_action '2.321' 30
assert_rejected_before_gcloud 'Invalid runner_ver'

run_action '2.321.0' '30; touch /tmp/shutdown-timeout-marker'
assert_rejected_before_gcloud 'Invalid shutdown_timeout'

run_action '2.321.0' 86401
assert_rejected_before_gcloud 'Invalid shutdown_timeout'

run_action '2.321.0' 999999999999999999999999
assert_rejected_before_gcloud 'Invalid shutdown_timeout'

run_action latest 30 'v2.321.0; touch /tmp/resolved-version-marker'
assert_rejected_before_gcloud 'Invalid resolved runner version'

run_action '2.321.0' 0
if [[ $status -ne 0 ]]; then
  printf 'valid explicit version failed:\n%s\n' "$output" >&2
  exit 1
fi

run_action latest 86400
if [[ $status -ne 0 ]]; then
  printf 'valid latest version failed:\n%s\n' "$output" >&2
  exit 1
fi

printf 'runner input validation tests passed\n'
