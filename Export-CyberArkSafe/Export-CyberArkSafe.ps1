# Define the directory you want to inspect and the output text file
$directoryPath = "D:\PrivateArk\Safes\Data"
$outputFile = "C:\Users\Administrator\Desktop\CyberArk Safes.txt"

# Retrieve all items in the directory that are folders 
# (-Directory parameter requires PowerShell 3.0 or later)
Get-ChildItem -Path $directoryPath -Directory | 
    Select-Object -ExpandProperty Name | 
    Out-File -FilePath $outputFile

Write-Host "Folder names exported to $outputFile"
