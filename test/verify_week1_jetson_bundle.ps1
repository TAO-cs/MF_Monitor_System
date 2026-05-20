$ErrorActionPreference = "Stop"

$template = ".\jetson_edge_disnet_cpp\configs\templates\device.ini.template"
$mainCpp = ".\jetson_edge_disnet_cpp\src\main.cpp"
$runner = ".\jetson_edge_disnet_cpp\scripts\run_rtsp_probe.sh"

if (-not (Test-Path $template)) {
  throw "device.ini.template missing"
}

$mainText = Get-Content $mainCpp -Raw -Encoding UTF8
if ($mainText -notmatch 'video_source') {
  throw "main.cpp does not support video_source yet"
}

$runnerText = Get-Content $runner -Raw -Encoding UTF8
if ($runnerText -notmatch 'CONFIG_PATH="\$\{1:-') {
  throw "run_rtsp_probe.sh does not accept external config path"
}
