#!/bin/bash
# Applies the repository's GitHub settings. Safe to run again. Needs admin access,
# and the CI workflow on main, since its check becomes required.
#   tool/github_setup.sh
set -e
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

# Merged branches tidy themselves away, and secrets are refused on push.
gh api -X PATCH "repos/$repo" --silent \
  -F delete_branch_on_merge=true \
  -F allow_auto_merge=true \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'

gh api -X PUT "repos/$repo/vulnerability-alerts" --silent
gh api -X PUT "repos/$repo/automated-security-fixes" --silent
gh api -X PUT "repos/$repo/private-vulnerability-reporting" --silent

# Main stays green and can't be rewritten. Admins can still push directly.
gh api -X PUT "repos/$repo/branches/main/protection" --input - --silent <<'JSON'
{
  "required_status_checks": { "strict": false, "contexts": ["Analyze and test", "Lint scripts and workflows"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false
}
JSON

echo "GitHub settings applied to $repo."
echo "To turn on Claude in pull requests and issues, run /install-github-app in Claude Code."
