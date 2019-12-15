<#
MindMiner  Copyright (C) 2017-2019  Oleg Samsonov aka Quake4
https://github.com/Quake4/MindMiner
License GPL-3.0
#>

class AlgoInfo {
	[bool] $Enabled
	[string] $Algorithm

	[string] ToString() {
		return $this | Select-Object Enabled, Algorithm
	}
}

class AlgoInfoEx : AlgoInfo {
	[string] $ExtraArgs
	[int] $BenchmarkSeconds
	
	[string] ToString() {
		return $this | Select-Object Enabled, Algorithm, ExtraArgs, BenchmarkSeconds
	}
}

class SpeedProfitInfo {
	[decimal] $Speed
	[decimal] $Profit

	SpeedProfitInfo([decimal] $speed, [decimal] $profit) {
		$this.Speed = $speed
		$this.Profit = $profit
	}
}