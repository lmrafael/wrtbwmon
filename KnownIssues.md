# DD-WRT v23 #

Although not officially supported, wrtbwmon has been reported to work with dd-wrt v23.
There is an issue with the PATH environment variable which seems to be different when running commands as cron jobs. Forcing it in the cron tasks will solve this, for example :
```
* * * * * root PATH=/bin:/usr/bin:/sbin:/usr/sbin:/jffs/sbin:/jffs/bin:/jffs/usr/sbin:/jffs/usr/bin && /jffs/wrtbwmon setup br0
```
Credits to Sam Fickling for reporting it.

# Upload/download reversed with VPN clients #

The ISP sees and bills the data "downloaded" by remote clients as being "uploaded" to them (ie LAN->router->internet->client). wrtbwmon is not aware the client is not on the LAN side and therefore will report it as downloaded data (ie router to client traffic).

Also, PPTP clients will not have their real MAC address but 00:00:00:00:00:00.