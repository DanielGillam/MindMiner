<#
MindMiner  Copyright (C) 2018-2019  Oleg Samsonov aka Quake4
https://github.com/Quake4/MindMiner
License GPL-3.0
#>

$PoolInfo = [PoolInfo]::new()
$PoolInfo.Name = (Get-Item $script:MyInvocation.MyCommand.Path).BaseName

$configfile = $PoolInfo.Name + [BaseConfig]::Filename
$configpath = [IO.Path]::Combine($PSScriptRoot, $configfile)

$Cfg = ReadOrCreatePoolConfig "Do you want to pass a rig to rent on $($PoolInfo.Name)" $configpath @{
	Enabled = $false
	Key = $null
	Secret = $null
	Region = $null
	EnabledAlgorithms = $null
	DisabledAlgorithms = $null
}

if ($global:HasConfirm -eq $true -and $Cfg -and [string]::IsNullOrWhiteSpace($Cfg.Key) -and [string]::IsNullOrWhiteSpace($Cfg.Secret)) {
	Write-Host "Create Api Key on `"https://www.miningrigrentals.com/account/apikey`" with grant to `"Manage Rigs`" as `"Yes`"." -ForegroundColor Yellow
	$Cfg.Key = Read-Host "Enter `"Key`""
	$Cfg.Secret = Read-Host "Enter `"Secret`""
	[BaseConfig]::Save($configpath, $Cfg)
}

if ($global:AskPools -eq $true -or !$Cfg) { return $null }

$PoolInfo.Enabled = $Cfg.Enabled
if (!$Cfg.Enabled) { return $PoolInfo }

if ([string]::IsNullOrWhiteSpace($Cfg.Key) -or [string]::IsNullOrWhiteSpace($Cfg.Secret)) {
	Write-Host "Fill in the `"Key`" and `"Secret`" parameters in the configuration file `"$configfile`" or disable the $($PoolInfo.Name)." -ForegroundColor Yellow
	return $PoolInfo
}

$servers = Get-Rest "https://www.miningrigrentals.com/api/v2/info/servers"
if (!$servers -or !$servers.success) {
	return $PoolInfo
}

if ([string]::IsNullOrWhiteSpace($Cfg.Region)) {
	$Cfg.Region = "us-central"
	switch ($Config.Region) {
		"$([eRegion]::Europe)" { $Cfg.Region = "eu" }
		"$([eRegion]::China)" { $Cfg.Region = "ap" }
		"$([eRegion]::Japan)" { $Cfg.Region = "ap" }
	}
	if ($Cfg.Region -eq "eu") {
		[string] $locale = "$($Cfg.Region)-$((Get-Host).CurrentCulture.TwoLetterISOLanguageName)"
		if ($servers.data | Where-Object { $_.region -match $locale }) {
			$Cfg.Region = $locale
		}
	}
}
$server = $servers.data | Where-Object { $_.region -match $Cfg.Region } | Select-Object -First 1	

if (!$server -or $server.Length -gt 1) {
	$servers = $servers.data | Select-Object -ExpandProperty region
	Write-Host "Set `"Region`" parameter from list ($(Get-Join ", " $servers)) in the configuration file `"$configfile`" or disable the $($PoolInfo.Name)." -ForegroundColor Yellow
	return $PoolInfo;
}

# check algorithms
$AlgosRequest = Get-Rest "https://www.miningrigrentals.com/api/v2/info/algos"
if (!$AlgosRequest -or !$AlgosRequest.success) {
	return $PoolInfo
}

$Algos = [Collections.Generic.Dictionary[string, PoolAlgorithmInfo]]::new()
$AlgosRequest.data | ForEach-Object {
	$Algo = $_
	$Pool_Algorithm = Get-Algo $Algo.name
	if ($Pool_Algorithm) {
		# $Algo.suggested_price.unit = $Algo.suggested_price.unit.ToLower().TrimEnd("h*day")
		# $Profit = [decimal]$Algo.suggested_price.amount / [MultipleUnit]::ToValueInvariant("1", $Algo.suggested_price.unit)
		$info = if ($Algo.stats.rented.rigs -eq "0") { "0" } else { "$($Algo.stats.rented.rigs)($($Algo.stats.rented.hash.nice))" }
		$info += "/$($Algo.stats.available.rigs)($($Algo.stats.available.hash.nice))"
		$Algos[$Pool_Algorithm] = [PoolAlgorithmInfo] @{
			Name = $PoolInfo.Name
			Algorithm = $Pool_Algorithm
			Profit = 0 # $Profit
			Info = $info
			Protocol = "stratum+tcp"
			Hosts = @($server.name)
			Port = $server.port
			PortUnsecure = $server.port
			User = "MindMiner"
			Password = "x"
			Priority = [Priority]::None
		}
	}
}

# check rented
try {
	$mrr = [MRR]::new($Cfg.Key, $Cfg.Secret);
	# $mrr.Debug = $true;
	$whoami = $mrr.Get("/whoami")
	if (!$whoami.authed) {
		Write-Host "MRR: Not authorized! Check Key and Secret." -ForegroundColor Yellow
		return $PoolInfo;
	}
	if ($whoami.permissions.rigs -ne "yes") {
		Write-Host "MRR: Need grant 'Manage Rigs' as 'Yes'." -ForegroundColor Yellow
		return $PoolInfo;
	}

	# balance
	if ($Config.ShowBalance -and $whoami.permissions.withdraw -ne "no") {
		$balance = $mrr.Get("/account/balance")
		$balance | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object {
			$confirmed = [decimal]$balance.$_.confirmed
			$unconfirmed = [decimal]$balance.$_.unconfirmed
			if ($confirmed -gt 0 -or $unconfirmed -gt 0) {
				$PoolInfo.Balance.Add($_, [BalanceInfo]::new($confirmed, $unconfirmed))
			}
		}
	}

	# check rigs
	$result = $mrr.Get("/rig/mine") | Where-Object { $_.name -match $Config.WorkerName }
	if ($result) {
		$rented_ids = @()
		$disable_ids = @()
		$enabled_ids = @()
		# smaller max
		if ([Config]::Max -eq 100) { [Config]::Max = 50 }
		# rented first
		$result | Sort-Object { [bool]$_.status.rented } -Descending | ForEach-Object {
			$Pool_Algorithm = Get-Algo $_.type
			if ($Pool_Algorithm -and [Config]::ActiveTypes.Length -gt 0 -and $rented_ids.Length -eq 0) {
				if ((($KnownAlgos.Values | Where-Object { $_ -contains $Pool_Algorithm } | Select-Object -First 1) | Select-Object -First 1) -ne $null) {
					$enabled_ids += $_.id
				}
				$_.price.type = $_.price.type.ToLower().TrimEnd("h")
				$Profit = [decimal]$_.price.BTC.price / [MultipleUnit]::ToValueInvariant("1", $_.price.type)
				$user = "$($whoami.username).$($_.id)"
				# possible bug - algo unknown, but rented
				if ($_.status.rented) {
					$rented_ids += $_.id
					# $redir = Ping-MRR $false $server.name $server.port $user $_.id
					$info = [SummaryInfo]::Elapsed([timespan]::FromHours($_.status.hours))
					$redir =  $mrr.Get("/rig/$($_.id)/port")
					$Algos[$Pool_Algorithm] = [PoolAlgorithmInfo]@{
						Name = $PoolInfo.Name
						Algorithm = $Pool_Algorithm
						Profit = $Profit * 0.97
						Info = $info
						Protocol = "stratum+tcp"
						Hosts = @($redir.server)
						Port = $redir.port
						PortUnsecure = $redir.port
						User = $user
						Password = "x"
						Priority = [Priority]::Unique
					}
					if (![Config]::MRRRented) {
						Write-Host "MRR: Rented $Pool_Algorithm for $info of $([SummaryInfo]::Elapsed([timespan]::FromHours($_.minhours))): $($_.name)" -ForegroundColor Yellow
					}
				}
				else {
					$info = [string]::Empty
					if ($Algos.ContainsKey($Pool_Algorithm)) {
						$info = $Algos[$Pool_Algorithm].Info
					}
					$Algos[$Pool_Algorithm] = [PoolAlgorithmInfo]@{
						Name = $PoolInfo.Name
						Algorithm = $Pool_Algorithm
						Profit = $Profit * 0.97
						Info = $info
						Protocol = "stratum+tcp"
						Hosts = @($server.name)
						Port = $server.port
						PortUnsecure = $server.port
						User = $user
						Password = "x"
						Priority = [Priority]::None
					}
				}
			}
			else {
				$disable_ids += $_.id
			}
		}

		$Algos.Values | ForEach-Object {
			$PoolInfo.Algorithms.Add($_)
		}

		[Config]::MRRRented = $rented_ids.Length -gt 0
		
		# on first run skip enable/disable
		if (($KnownAlgos.Values | Measure-Object -Property Count -Sum).Sum -gt 0) {
			# disable
			$dids = @()
			$result | Where-Object { $_.available_status -match "available" -and $disable_ids -contains $_.id } | ForEach-Object {
				$alg = Get-Algo $_.type
				Write-Host "MRR: Disable $alg`: $($_.name)"
				$dids += $_.id
			}
			if ($dids.Length -gt 0) {
				$mrr.Put("/rig/$($dids -join ';')", @{ "status" = "disabled" })
			}
			# enable
			$eids = @()
			$result | Where-Object { $_.available_status -notmatch "available" -and $enabled_ids -contains $_.id -and $disable_ids -notcontains $_.id } | ForEach-Object {
				$alg = Get-Algo $_.type
				Write-Host "MRR: Available $alg`: $($_.name)"
				$eids += $_.id
			}
			if ($eids.Length -gt 0) {
				$mrr.Put("/rig/$($eids -join ';')", @{ "status" = "enabled" })
			}
			# ping 
			$result | Where-Object { !$_.status.rented -and $enabled_ids -contains $_.id -and $disable_ids -notcontains $_.id } | ForEach-Object {
				$alg = Get-Algo $_.type
				Write-Host "MRR: Online $alg`: $($_.name)"
				Ping-MRR $server.name $server.port "$($whoami.username).$($_.id)" $_.id
			}
		}
	}
	else {
		Write-Host "MRR: No compatible rigs found! Write it '$($Config.WorkerName)' string to MRR rig name." -ForegroundColor Yellow
	}
	# info as standart pool
	$PoolInfo.HasAnswer = $true
	$PoolInfo.AnswerTime = [DateTime]::Now
}
catch {
	Write-Host $_
}
finally {
	if ($mrr) {	$mrr.Dispose() }
}

return $PoolInfo