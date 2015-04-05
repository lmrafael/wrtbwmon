# What you need #

Supported : any router running either
  * DD-WRT (including routers with only 2mb flash **with micro-plus**)
  * OpenWRT
  * Tomato

Bare minimum :
  * a router running some flavor of linux
  * shell access to it (telnet, ssh)
  * the following commands built in : echo touch mv rm sed cat chmod grep cut date iptables

# Tutorials #

## DD-WRT v24 ##
Step 1 : Get the script onto your router
If you have jffs (on any other permanent storage - cifs, mmc...) enabled, I recommend you put the script on that partition. This way it will not get lost after a reboot. You can execute the following command directly (telnet, ssh, or from the web interface in Administration/Commands) :
```
wget http://wrtbwmon.googlecode.com/files/wrtbwmon -O /jffs/wrtbwmon
```
Then make it executable :
```
chmod +x /jffs/wrtbwmon
```

If you don't have jffs, put the script in /tmp instead :
```
wget http://wrtbwmon.googlecode.com/files/wrtbwmon -O /tmp/wrtbwmon && chmod +x /tmp/wrtbwmon
```
However it will be lost upon reboot. One way to circumvent this is to schedule a cron job that will redownload it if missing :
```
* * * * * root [ ! -f /tmp/wrtbwmon ] && wget http://wrtbwmon.googlecode.com/files/wrtbwmon -O /tmp/wrtbwmon && chmod +x /tmp/wrtbwmon
```

Step 1a : Database storage
The database is a file that will contain the accounting records. It will be written to very often, so it is not recommended to put it on flash memory (ie jffs).
If you have cifs enabled, put it there.
If you don't, then put it in RAM, in /tmp. Then hope your router will not need to be rebooted, else all the counters will start over from zero.
Note : if you put it in RAM and have access to some online storage, you can schedule a periodic backup task and restore it if missing, for example :
```
15 * * * * root cd /tmp && ftpput -u username -p password usage.db . some_ftp_server_url
* * * * * root [ ! -f /tmp/usage.db ] && wget some_url/usage.db -O /tmp/usage.db
```

Step 2 : using it

You need to perform 3 tasks periodically :
  * set up the counters to track connected hosts (frequently - ie every minute)
  * read those counters and update the database (somewhat frequently - ie every 30 minutes)
  * generate the report (when you see fit - ie every 2 hours)

Cron jobs will do that :
```
* * * * * root /tmp/wrtbwmon setup br0
*/30 0-3 * * * root /tmp/wrtbwmon update /tmp/usage.db peak
*/30,59 4-8 * * * root /tmp/wrtbwmon update /tmp/usage.db offpeak
*/30 9-23 * * * root /tmp/wrtbwmon update /tmp/usage.db peak
45 */2 * * * root /tmp/wrtbwmon publish /tmp/usage.db /tmp/www/usage.htm
```

Note : In this example the off-peak counters get updated from 4:00 to 8:59, the peak counters the rest of the day.

Every two hours (or whatever frequency the cron job is) a report will be generated. It can be accessed at http://your_router_ip/user/usage.htm

## OpenWRT Kamikaze / Whiterussian ##

The instruction are basically the same as for DD-WRT. The only differences are :
**ftpput command is unavailable thus database cannot be uploaded. You can use the wput package instead (installed through ipkg).** The integrated web interface will ask for the admin password even for external pages, so if you want the usage report to be public you may want to put it somewhere else (upload it, put it on a samba share...). /www is mapped to the flash so it is not advisable to put the report there anyway.

## Tomato ##

Tomato is quite similar to dd-wrt, except the usage of cru to manage cron jobs.
The integrated web interface will ask for the admin password even for external pages, so if you want the usage report to be public you may want to put it somewhere else (upload it, put it on a cifs share...).

Put the script on the jffs partition or on a samba share, make it executable, and add the cron jobs.

The easiest way to do the latter is to declare them in the WAN-up script :

```
# restore database if missing
[ ! -f /tmp/usage.db ] && wget some_url/usage.db -O /tmp/usage.db
cru a wrtbwmon_setup "* * * * * /jffs/wrtbwmon setup br0"
cru a wrtbwmon_updatepeak "*/30,59 0-3,9-23 * * * /jffs/wrtbwmon update /tmp/usage.db peak"
cru a wrtbwmon_updateoffpeak "*/30,59 4-8 * * * /jffs/wrtbwmon update /tmp/usage.db offpeak"
cru a wrtbwmon_publish "40 */2 * * * /jffs/wrtbwmon publish /tmp/usage.db /tmp/usage.htm"
cru a wrtbwmon_backup "15 * * * * cd /tmp && ftpput -u username -p password usage.db . some_ftp_server_url"
```

Adapt to you own needs.


That's it !

If you found this script useful, donations are welcome at 1wrt3qXmu8xoXpJe99LapNFUCjwr7oVvh