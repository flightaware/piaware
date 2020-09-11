# piaware-config Command Line Tool

The `piaware-config` command can be used to start/stop/restart the piaware client and configure piaware settings.
  
Usage:
  
#### Start piaware:
```
piaware-config -start
```
#### Stop piaware:
```
piaware-config -stop
```
#### Restart piaware:
```
piaware-config -restart
```
#### Show currently configured (non-default) piaware settings
```
piaware-config -show
```
#### Show all piaware settings
```
piaware-config -showall
```
#### Set a piaware config setting
- Syntax: piaware-config <setting> <value>
```
piaware-config wireless-ssid MyWifiNetwork
```
  
#### Clear a piaware-config setting
```
piaware-config wireless-ssid ""
```
