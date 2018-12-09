<#
MindMiner  Copyright (C) 2017-2018  Oleg Samsonov aka Quake4
https://github.com/Quake4/MindMiner
License GPL-3.0
#>

if ([Config]::UseApiProxy) { return $null }
if (!$Config.Wallet.BTC -and !$Config.Wallet.NiceHash) { return $null }

$PoolInfo = [PoolInfo]::new()
$PoolInfo.Name = (Get-Item $script:MyInvocation.MyCommand.Path).BaseName

$Cfg = ReadOrCreatePoolConfig "Do you want to mine on $($PoolInfo.Name) (>0.1 BTC every 24H, >0.001 BTC ~ weekly)" ([IO.Path]::Combine($PSScriptRoot, $PoolInfo.Name + [BaseConfig]::Filename)) @{
	Enabled = $true
	AverageProfit = "20 min"
	EnabledAlgorithms = $null
	DisabledAlgorithms = $null
}
if ($global:AskPools -eq $true -or !$Cfg) { return $null }

if ($Config.Wallet.NiceHash) {
	$Wallet = $Config.Wallet.NiceHash
	$Sign = "NiceHash"
	$Fee = 2
} else {
	$Wallet = $Config.Wallet.BTC
	$Sign = "BTC"
	$Fee = 5
}

if (!$Wallet) { return $null }

$PoolInfo.Enabled = $Cfg.Enabled
$PoolInfo.AverageProfit = $Cfg.AverageProfit

if (!$Cfg.Enabled) { return $PoolInfo }
[decimal] $Pool_Variety = if ($Cfg.Variety) { $Cfg.Variety } else { 0.95 }

try {
	$Request = Get-UrlAsJson "https://api.nicehash.com/api?method=simplemultialgo.info"
}
catch { return $PoolInfo }

try {
	if ($Config.ShowBalance) {
		$RequestBalance = Get-UrlAsJson "https://api.nicehash.com/api?method=stats.provider&addr=$Wallet"
	}
}
catch { }

if (!$Request) { return $PoolInfo }
$PoolInfo.HasAnswer = $true
$PoolInfo.AnswerTime = [DateTime]::Now

if ($RequestBalance) {
	[decimal] $balance = 0
	$RequestBalance.result.stats | ForEach-Object {
		$balance += [decimal]($_.balance)
	}
	$PoolInfo.Balance.Add("BTC", [BalanceInfo]::new($balance, 0))
	Remove-Variable balance
}

$Pool_Region = "usa"
# "eu", "usa", "hk", "jp", "in", "br"
switch ($Config.Region) {
	"$([eRegion]::Europe)" { $Pool_Region = "eu" }
	"$([eRegion]::China)" { $Pool_Region = "hk" }
	"$([eRegion]::Japan)" { $Pool_Region = "jp" }
}

$Request.result.simplemultialgo | Where-Object paying -GT 0 | ForEach-Object {
	$Pool_Algorithm = Get-Algo $_.name $false
	if ($Pool_Algorithm -and (!$Cfg.EnabledAlgorithms -or $Cfg.EnabledAlgorithms -contains $Pool_Algorithm) -and $Cfg.DisabledAlgorithms -notcontains $Pool_Algorithm) {
		$Pool_Host = $_.name + ".$Pool_Region.nicehash.com"
		$Pool_Port = $_.port
		$Pool_Diff = if ($AllAlgos.Difficulty.$Pool_Algorithm) { "d=$($AllAlgos.Difficulty.$Pool_Algorithm)" } else { [string]::Empty }
		$Pool_Protocol = "stratum+tcp"
		if ($Config.SSL -eq $true) {
			if ($Pool_Algorithm -contains "equihash") {
				$Pool_Protocol = "stratum+ssl"
				$Pool_Port = "3" + $Pool_Port
			}
		}

		$Profit = [decimal]$_.paying * (100 - $Fee) / 100 * $Pool_Variety / 1000000000
		$ProfitFast = $Profit
		$Profit = Set-Stat -Filename $PoolInfo.Name -Key $Pool_Algorithm -Value $Profit -Interval $Cfg.AverageProfit

		$PoolInfo.Algorithms.Add([PoolAlgorithmInfo] @{
			Name = $PoolInfo.Name
			Algorithm = $Pool_Algorithm
			Info = $Config.Region
			InfoAsKey = $true
			Profit = if (($Config.Switching -as [eSwitching]) -eq [eSwitching]::Fast) { $ProfitFast } else { $Profit }
			Protocol = $Pool_Protocol
			Host = $Pool_Host
			Port = $Pool_Port
			PortUnsecure = $_.port
			User = "$(([Config]::WalletPlaceholder -f $Sign)).$([Config]::WorkerNamePlaceholder)"
			Password = if (![string]::IsNullOrWhiteSpace($Pool_Diff)) { $Pool_Diff } else { $Config.Password }
		})
	}
}

Remove-Stat -Filename $PoolInfo.Name -Interval $Cfg.AverageProfit

$PoolInfo