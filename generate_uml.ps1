$InputFile = $args[0]
$OutputFile = $args[1]

if ([string]::IsNullOrWhiteSpace($InputFile) -or [string]::IsNullOrWhiteSpace($OutputFile)) {
    Write-Host "Error: Missing parameters." -ForegroundColor Red
    Write-Host "Usage: .\generate_uml.ps1 <file_input.md> <file_output.pdf|svg|png>" -ForegroundColor Yellow
    exit 1
}

Write-Host "Processing $InputFile..." -ForegroundColor Cyan

# Usa npx per invocare Mermaid CLI (tema dark e sfondo trasparente)
npx @mermaid-js/mermaid-cli -i $InputFile -o $OutputFile -t dark -b transparent

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Successfully generated: $OutputFile" -ForegroundColor Green
} else {
    Write-Host "❌ Error generating file." -ForegroundColor Red
}