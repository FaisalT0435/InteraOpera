#!/usr/bin/env bash
set -e

export PATH="$PWD/bin:$PATH"

echo -e "\n\033[1;36m==> Destroying Terraform resources (kind cluster + Helm)...\033[0m"
cd infra
terraform destroy -auto-approve
cd ..
echo -e "\033[1;32m✅ Platform destroyed.\033[0m"
