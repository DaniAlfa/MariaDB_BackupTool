# MariaDB_BackupTool
The script BackupTool its an utility to make, restore and schedule physical backups of a mariadb sever.
It allows to make full or incremental backups, of all the server or a certain database, with compression.

The script uses a user selected directory to save all the backups. The path to this directory its saved in a .cnf file, /etc/BackupTool.cnf. If the directory is not found
or doesn't exist, the script will ask the user to create a new one.

### NOTE: THE SCRIPT MUST BE EXECUTED AS ROOT

## Options:
    (1) Create a physical backup
    (2) Create an incremental physical backup
    (3) Restore backup
    (4) Schedule physical backup
    (5) Schedule incremental physical backup
    (6) Remove backup jobs
