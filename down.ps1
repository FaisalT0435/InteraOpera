Write-Host "==> Destroying Terraform resources (kind cluster + Helm)..." -ForegroundColor Cyan
Push-Location infra
terraform destroy -auto-approve
Pop-Location
Write-Host "✅ Platform destroyed." -ForegroundColor Green
