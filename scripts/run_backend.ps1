Param()

$ErrorActionPreference = "Stop"

if (-not (Test-Path ".venv")) {
  python -m venv .venv
}

.\.venv\Scripts\Activate.ps1
pip install -r backend\requirements.txt
Set-Location backend
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
