Import-Module ActiveDirectory
$ErrorActionPreference = "Stop"

$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName   # DC=lab,DC=local
$dnsRoot  = $domain.DNSRoot             # lab.local

# Map Department -> OU DN
$ouPathMap = @{
  "Sales" = "OU=Sales,$domainDN"
  "HR"    = "OU=HR,$domainDN"
}

# Helper: ensure a dept group exists inside its OU
function Ensure-DeptGroup {
  param([string]$Dept)
  $ouDN      = $ouPathMap[$Dept]
  $groupName = "$Dept`Group"
  $g = Get-ADGroup -LDAPFilter "(cn=$groupName)" -SearchBase $ouDN -SearchScope OneLevel -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $g) {
    $g = New-ADGroup -Name $groupName -SamAccountName $groupName -GroupScope Global -GroupCategory Security -Path $ouDN -PassThru
  }
  return $g
}

# Load your CSV
$csvPath = "C:\AD_Scripts\NewUsers.csv"
$rows = Import-Csv $csvPath

# Prepare groups by dept once
$groupByDept = @{}
foreach ($dept in ($rows | Select-Object -Expand Department -Unique)) {
  if (-not $dept) { continue }
  if (-not $ouPathMap[$dept]) { throw "No OU mapping for Department '$dept'." }
  $groupByDept[$dept] = Ensure-DeptGroup -Dept $dept
}

foreach ($u in $rows) {
  # Trim & validate
  $first = ($u.FirstName  -as [string]).Trim()
  $last  = ($u.LastName   -as [string]).Trim()
  $sam   = ($u.UserName   -as [string]).Trim()
  $dept  = ($u.Department -as [string]).Trim()
  $pwd   = ($u.Password   -as [string])

  if (!$first -or !$last -or !$sam -or !$dept -or !$pwd) {
    Write-Warning "Skipping row (missing fields): $($u | ConvertTo-Json -Compress)"
    continue
  }

  $ouDN     = $ouPathMap[$dept]
  $full     = "$first $last"
  $upn      = "$sam@$dnsRoot"
  $securePw = ConvertTo-SecureString $pwd -AsPlainText -Force

  $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties DistinguishedName -ErrorAction SilentlyContinue

  if ($existing) {
    # Update + move if needed
    Set-ADUser -Identity $existing -GivenName $first -Surname $last -DisplayName $full -UserPrincipalName $upn -Department $dept
    if ($existing.DistinguishedName -notlike "*$ouDN") {
      Move-ADObject -Identity $existing.DistinguishedName -TargetPath $ouDN
      Write-Host "Moved $sam to $ouDN"
    }
  } else {
    # Create in the correct OU
    $params = @{
      Name                  = $full
      GivenName             = $first
      Surname               = $last
      DisplayName           = $full
      SamAccountName        = $sam
      UserPrincipalName     = $upn
      Department            = $dept
      Path                  = $ouDN
      AccountPassword       = $securePw
      Enabled               = $true
      ChangePasswordAtLogon = $true
    }
    New-ADUser @params
    Write-Host "Created $sam in $ouDN"
  }

  # Ensure group membership
  try {
    Add-ADGroupMember -Identity $groupByDept[$dept] -Members $sam -ErrorAction Stop
  } catch {
    # Already a member is fine
  }
}
