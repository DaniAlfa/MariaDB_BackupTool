#!/bin/bash

####FUNCIONES


getGeneralBackupDir(){
	if [ -f "/etc/BackupTool.cnf" ]; then
        read -r backupsDir < "/etc/BackupTool.cnf"
        if [ ! -d "$backupsDir" ]; then
        	rm "/etc/BackupTool.cnf"
        	echo "Error: El archivo de configuracion es incorrecto" 1>&2
   			exit 1
   		fi
   	else
   		echo ":: Introduzca la ruta al directorio de backups general"
		echo -n "-->"
		read backupsDir
		if [ -d "$backupsDir" ]; then
			backupsDir=$(realpath "$backupsDir")
        	echo "$backupsDir" > "/etc/BackupTool.cnf"
        else
        	echo "Error: La ruta introducida no apunta a ningun directorio" 1>&2
   			exit 1
   		fi
    fi
}

printBackupsDir(){
	local backs=$(ls "$1" | sort -t_ -k2 -g -r)
	for dir in $backs
	do
		if [ -f "$1/$dir/backInfo" ]; then
			echo ":: $dir --> $(printBackInfo "$1/$dir/backInfo")"
		fi
	done
}

printBackInfo(){
	local type=""
	local db=""
	local date=""
	exec 6<&0
	exec < "$1"
	read -r type
	read -r db
	read -r date
	exec 0<&6 6<&-
	echo "Tipo: $type, DB: ${db#*;}, Fecha: $date"
}

askForBackupDestDir(){
	destDir=""
	dateExt=$(date +"%Y%m%d-%H%M%S")
	dateForm=$(date +"%d/%m/%Y-%H:%M:%S")

	echo ":: Introduzca el directorio donde desea guardar el Backup (debe ser vacio o no existir)"
	read -e -i "$backupsDir/Back_$dateExt" -p "-->" destDir

	if [ -f "$destDir" ]; then
        echo "Error: $destDir es un archivo, debe ser un directorio" 1>&2
   		exit 1
    fi
	if [ -d "$destDir" ]; then
  		files=$(shopt -s nullglob dotglob; echo "$destDir/"*)
		if (( ${#files} ))
		then
		  echo "Error: El directorio $destDir debe estar vacio" 1>&2
		  exit 1
		fi
	fi
}

askForDataBasesToBackup(){
	dataBases=""
	local resp="N"
	echo ":: Desea selecionar las bases de datos para el backup? (S,N)"
	echo -n "-->"
	read resp
	case $resp in
		S|s)
		echo ":: Introduzca las bases de datos separadas por espacios de entre las siguientes:"
		{ errorOut=$(mysql -uroot -e "SHOW DATABASES" 2>&1 1>&3-) ;} 3>&1
		if [ ! -z "$errorOut" ]; then
			echo "Error: Fallo en consulta a la BD --> ${errorOut}" 1>&2
			exit 1
		fi
		echo -n "-->"
		read dataBases
		;;
		*)
		;;
	esac
}

askForIncDir(){
	baseDir=""
	echo ":: El directorio general contiene los siguientes backups:"
	printBackupsDir "$backupsDir"
	echo ":: Introduzca el directorio del Backup base/incremental para realizar el nuevo incremento"
	read -e -i "$backupsDir/$(ls "$backupsDir" | sort -t_ -k2 -g -r | head -n 1)" -p "-->" baseDir
	if [ ! -f "$baseDir/backInfo" ]; then
    	echo "Error: El directorio de backup no contiene el archivo de informacion" 1>&2
    	exit 1
	fi
}

askForRestoreDir(){
	restoreDir=""
	echo ":: El directorio general contiene los siguientes backups:"
	printBackupsDir "$backupsDir"
	echo ":: Introduzca el directorio del backup a restaurar"
	read -e -i "$backupsDir/$(ls "$backupsDir" | sort -t_ -k2 -g -r | head -n 1)" -p "-->" restoreDir
	if [ ! -f "$restoreDir/backInfo" ]; then
    	echo "Error: El directorio de backup no contiene el archivo de informacion" 1>&2
    	exit 1
	fi
}

readDataBasesFromFile(){
	dataBases=""
	local line=""
	local i=0
	while read -r line
	do
		if [ $i -eq 1 ]; then
			if [[ "$line" != "full" ]]; then
				dataBases=${line#*;}
			fi
			break
		fi
	  	((i++))
	done < "$1"
}

makePhysicBackup(){
	local backInfo=""
	getGeneralBackupDir
	askForBackupDestDir
	askForDataBasesToBackup

	mkdir "$destDir"
	local tempf=$(mktemp)

	if [ -z "$dataBases" ]; then
		backInfo="base\nfull\n$dateForm"
		echo "Comando --> mariabackup --backup --user=root --stream=xbstream > $tempf"
		mariabackup --backup --user=root --stream=xbstream > "$tempf"
	else
		backInfo="base\npartial;${dataBases}\n$dateForm"
		echo "Comando --> mariabackup --backup --databases=\"$dataBases\" --user=root --stream=xbstream > $tempf"
		mariabackup --backup --databases="$dataBases" --user=root --stream=xbstream > "$tempf"
	fi

	if [ -s "$tempf" ]; then #Si no esta vacio
		cat "$tempf" | gzip > "$destDir/backupstream.gz"
		echo -e "$backInfo" > "$destDir/backInfo"
		echo ":: Backup realizado con exito"
		rm "$tempf"
	else
		rm "$tempf"
		rm -R "$destDir"
		echo "Error: No se pudo realizar el backup" 1>&2
		exit 1
	fi
}

makePhysicIncBackup(){
	local pathToBase=""
	local backInfo=""
	local incrementalOpt=""

	getGeneralBackupDir
	askForIncDir
	readDataBasesFromFile "$baseDir/backInfo"
	askForBackupDestDir
	incrementalOpt="--incremental-basedir=${baseDir}"
	pathToBase=$(realpath --relative-to="$destDir" "$baseDir")

	local tempf=$(mktemp)
	local tempDir=$(mktemp -d)
	mkdir "$destDir"
	cd "$tempDir"
	gunzip -c "$baseDir/backupstream.gz" | mbstream -x

	if [ -z "$dataBases" ]; then
		backInfo="inc;${pathToBase}\nfull\n$dateForm"
		echo "Comando --> mariabackup --backup --incremental-basedir=$baseDir --user=root > $tempf"
		mariabackup --backup --incremental-basedir="$tempDir" --user=root --stream=xbstream > "$tempf"
	else
		backInfo="inc;${pathToBase}\npartial;${dataBases}\n$dateForm"
		echo "Comando --> mariabackup --backup --incremental-basedir=$baseDir --databases=\"$dataBases\" --user=root > $tempf"
		mariabackup --backup --incremental-basedir="$tempDir" --databases="$dataBases" --user=root --stream=xbstream > "$tempf"
	fi
	
	if [ -s "$tempf" ]; then #Si no esta vacio
		cat "$tempf" | gzip > "$destDir/backupstream.gz"
		echo -e "$backInfo" > "$destDir/backInfo"
		echo ":: Backup realizado con exito"
		rm "$tempf"
		rm -R "$tempDir"
	else
		rm "$tempf"
		rm -R "$tempDir"
		rm -R "$destDir"
		echo "Error: No se pudo realizar el backup" 1>&2
		exit 1
	fi
}

getBackupFileSecuence(){
	numFiles=0
	cd "$1"
	local actualFile="$1/backInfo"
	local end=0

	while [ $end -eq 0 ]
	do
		local line=""
		if [ ! -f "$actualFile" ]; then
			echo "Error: El archivo $actualFile no existe" 1>&2
			exit 1
		fi
		read -r line < "$actualFile"
		if [[ "$line" == "base" ]]; then
			fileSecuence[$numFiles]="$actualFile"
			((numFiles++))
			end=1
		elif [[ "${line%%;*}" == "inc" ]]; then
			fileSecuence[$numFiles]="$actualFile"
			((numFiles++))
			cd "${line#*;}"
			actualFile="$(pwd)/backInfo"
		else
			echo "Error: El archivo $actualFile esta mal formado" 1>&2
			exit 1
		fi
	done
}

getDataDir(){
	{ errorOut=$(mysql -s -N -uroot  information_schema -e 'SELECT Variable_Value FROM GLOBAL_VARIABLES WHERE Variable_Name = "datadir"' 2>&1 1>&3-) ;} 3>&1
	if [ ! -z "$errorOut" ]; then
		echo "Error: Fallo en consulta a la BD --> ${errorOut}" 1>&2
		echo ":: No se pudo leer el directorio de datos, introduzcalo manualmente: (por defecto /var/lib/mysql/)" 1>&2
		echo -n "-->" 1>&2
		read dir
		echo "$dir"
	fi
}

getAndCheckDataDir(){
	dataDir=$(getDataDir)
	if [ ! -d "$dataDir" ] || [[ "$dataDir" == "error" ]]; then
		exit 1
	fi
	dataDir=$(echo "$dataDir" | tr -s '/')
	mapfile -t temp < <( echo /* ; echo /*/ )
	temp+=('/')
	if [[ " ${temp[@]} " =~ " ${dataDir} " ]]; then
		echo "Error: Directorio de sistema $dataDir como directorio de datos" 1>&2
		exit 1
	fi
}

restoreBaseBackup(){
	getAndCheckDataDir
	local tempDir=$(mktemp -d)
	cd "$tempDir"
	gunzip -c "${fileSecuence[0]%/*}/backupstream.gz" | mbstream -x
	echo "Comando --> systemctl stop mariadb"
	systemctl stop mariadb 
	if [ -z "$dataBases" ]; then
		echo "Comando --> rm -R $dataDir/*"
		rm -R "$dataDir"/*
		echo "Comando --> mariabackup --prepare --target-dir=${fileSecuence[0]%/*}"
		mariabackup --prepare --target-dir="$tempDir" 2>&1
		echo "Comando --> mariabackup --copy-back --target-dir=${fileSecuence[0]%/*}"
		mariabackup --copy-back --target-dir="$tempDir" 2>&1
	else
		echo "Comando --> mariabackup --prepare --export --target-dir=${fileSecuence[0]%/*}"
		mariabackup --prepare --export --target-dir="$tempDir" 2>&1
		echo "Comando --> cp -R ${fileSecuence[0]%/*}/* $dataDir"
		cp -R "$tempDir"/* "$dataDir"
	fi
	rm -R "$tempDir"
	echo "Comando --> chown -R mysql:mysql $dataDir/*"
	chown -R mysql:mysql "$dataDir"/*
	echo "Comando --> systemctl start mariadb"
	systemctl start mariadb
}

restoreIncBackup(){
	getAndCheckDataDir

	local tempTargetDir=$(mktemp -d)
	local tempIncDir=$(mktemp -d)

	cd "$tempTargetDir"
	gunzip -c "${fileSecuence[(( $numFiles - 1 ))]%/*}/backupstream.gz" | mbstream -x
	cd "$tempIncDir"
	if [ -z "$dataBases" ]; then
		echo "Comando --> mariabackup --prepare --target-dir=${fileSecuence[(( $numFiles - 1 ))]%/*}"
		mariabackup --prepare --target-dir="$tempTargetDir" 2>&1
		for (( i=$numFiles - 2; i>=0; i-- ))
		do
			gunzip -c "${fileSecuence[(( $i ))]%/*}/backupstream.gz" | mbstream -x
			echo "Comando --> mariabackup --prepare --target-dir=${fileSecuence[(( $numFiles - 1 ))]%/*} --incremental-dir=${fileSecuence[(( $i ))]%/*}"
			mariabackup --prepare --target-dir="$tempTargetDir" --incremental-dir="$tempIncDir" 2>&1
			rm -R "$tempIncDir"/*
		done

	else
		echo "Comando --> mariabackup --export --prepare --target-dir=${fileSecuence[(( $numFiles - 1 ))]%/*}"
		mariabackup --prepare --export --target-dir="$tempTargetDir" 2>&1
		for (( i=$numFiles - 2; i>=0; i-- ))
		do
			gunzip -c "${fileSecuence[(( $i ))]%/*}/backupstream.gz" | mbstream -x
			echo "Comando --> mariabackup --prepare --target-dir=${fileSecuence[(( $numFiles - 1 ))]%/*} --incremental-dir=${fileSecuence[(( $i ))]%/*}"
			mariabackup --prepare --export --target-dir="$tempTargetDir" --incremental-dir="$tempIncDir" 2>&1
			rm -R "$tempIncDir"/*
		done
	fi

	local newDate=$(sed '3q;d' ${fileSecuence[0]})
	echo "$newDate"
	for (( i=$numFiles - 2; i>=0; i-- ))
	do
		echo "Comando --> rm -R ${fileSecuence[$i]%/*}"
		rm -R "${fileSecuence[$i]%/*}"
	done

	echo "Comando --> mv ${fileSecuence[(( $numFiles - 1 ))]%/*} ${fileSecuence[0]%/*}"
	mv "${fileSecuence[(( $numFiles - 1 ))]%/*}" "${fileSecuence[0]%/*}"

	rm -R "${fileSecuence[0]%/*}"/*
	
	cp -R "$tempTargetDir"/* "${fileSecuence[0]%/*}"
	cd "${fileSecuence[0]%/*}"
	mbstream -c $(find . -type f) | gzip > "${fileSecuence[0]%/*}/backupstream.gz"
	cp "${fileSecuence[0]%/*}/backupstream.gz" "$tempTargetDir"
	rm -R "${fileSecuence[0]%/*}"/*
	cp "$tempTargetDir/backupstream.gz" "${fileSecuence[0]%/*}"

	if [ -z "$dataBases" ]; then
		echo -e "base\nfull\n$newDate" > "${fileSecuence[0]}"
		echo "Comando --> systemctl stop mariadb"
		systemctl stop mariadb 
		echo "Comando --> rm -R $dataDir/*"
		rm -R "$dataDir"/*
		echo "Comando --> mariabackup --copy-back --target-dir=${fileSecuence[0]%/*}"
		mariabackup --copy-back --target-dir="$tempTargetDir" 2>&1
	else
		echo -e "base\npartial;${dataBases}\n$newDate" > "${fileSecuence[0]}"
		echo "Comando --> systemctl stop mariadb"
		systemctl stop mariadb 
		echo "Comando --> cp -R ${fileSecuence[0]%/*}/* $dataDir"
		cp -R "$tempTargetDir"/* "$dataDir"
	fi
	echo "Comando --> chown -R mysql:mysql $dataDir/*"
	chown -R mysql:mysql "$dataDir"/*
	echo "Comando --> systemctl start mariadb"
	systemctl start mariadb

	rm -R "$tempTargetDir"
	rm -R "$tempIncDir"
}

restoreBackup(){
	local temp=""
	getGeneralBackupDir
	askForRestoreDir
	getBackupFileSecuence "$restoreDir"
	readDataBasesFromFile "${fileSecuence[0]}"

	if (( $numFiles == 1 )); then
		temp=${fileSecuence[0]%/*}
		echo ":: Se restaurara el backup ${temp##*/}-($(printBackInfo "${fileSecuence[0]}"))"
		echo ":: El servidor se desconectara momentaneamente, ¿continuar? (S,N)"
		echo -n "-->"
		read resp
		case $resp in
			S|s)
			restoreBaseBackup
			;;
			*)
			exit 0
			;;
		esac
	else
		echo ":: Se restaurara la siguiente secuencia de backups"
		for (( i=0;i<$numFiles;i++ ))
		do
			temp=${fileSecuence[$i]%/*}
			if (( i == $numFiles - 1 )); then
				echo ":: ${temp##*/}-($(printBackInfo "${fileSecuence[$i]}"))"
			else
				echo ":: ${temp##*/}-($(printBackInfo "${fileSecuence[$i]}")) --> "
			fi
		done
		echo ":: Los incrementos se sincronizaran con el base ${temp##*/}, se eliminaran y el base se actualizara a la fecha del ultimo incremento"
		echo ":: El servidor se desconectara momentaneamente, ¿continuar? (S,N)"
		echo -n "-->"
		read resp
		case $resp in
			S|s)
			restoreIncBackup
			;;
			*)
			exit 0
			;;
		esac
	fi
}

askForScheduleTime(){
	echo ":: Introduce los dias de la semana en los que deseas planificar el backup:"
	echo ":: 0 o 7 es Domingo, 1 Lunes, 2 Martes..."
	echo ":: Puedes introducirlo como '1-5' para hacer backup cada dia de Lunes a Viernes o '*' para todos los dias"
	echo -n "-->"
	read days
	echo ":: Introduce los meses (1-12) o '*'"
	echo -n "-->"
	read months
	echo ":: Introduce las horas (0-23) o '*'"
	echo -n "-->"
	read hours
	echo ":: Introduce los minutos (0-59) o '*'"
	echo -n "-->"
	read mins
}

schedulePhysicBackup(){
	getGeneralBackupDir
	askForDataBasesToBackup
	askForScheduleTime

	cat <<-EOF >"$backupsDir/schedPhy.sh"
	#!/bin/bash
	dataBases=$dataBases
	dateExt=\$(date +"%Y%m%d-%H%M%S")
	dateForm=\$(date +"%d/%m/%Y-%H:%M:%S")
	destDir="$backupsDir/Back_\$dateExt"
	backInfo=""

	mkdir "\$destDir"
	tempf=\$(mktemp)
	
	if [ -z "\$dataBases" ]; then
		backInfo="base\nfull\n\$dateForm"
		mariabackup --backup --user=root --stream=xbstream > "\$tempf"
	else
		backInfo="base\npartial;\${dataBases}\n\$dateForm"
		mariabackup --backup --databases="\$dataBases" --user=root --stream=xbstream > "\$tempf"
	fi
	if [ -s "\$tempf" ]; then #Si no esta vacio
		cat "\$tempf" | gzip > "\$destDir/backupstream.gz"
		echo -e "$backInfo" > "\$destDir/backInfo"
		rm "\$tempf"
	else
		rm "\$tempf"
		rm -R "\$destDir"
		exit 1
	fi
	EOF

	chmod 744 "$backupsDir/schedPhy.sh"

	crontab -l > mycron
	echo "$mins $hours * $months $days $backupsDir/schedPhy.sh" >> mycron
	crontab mycron
	rm mycron

	echo ":: Tarea planificada con exito"
}

schedulePhysicIncBackup(){
	getGeneralBackupDir
	askForDataBasesToBackup
	askForScheduleTime
	echo ":: Los incrementos se realizaran sobre el backup mas reciente"

	cat <<-EOF >"$backupsDir/schedIncPhy.sh"
	#!/bin/bash
	dataBases=$dataBases
	backInfo=""
	dateExt=\$(date +"%Y%m%d-%H%M%S")
	dateForm=\$(date +"%d/%m/%Y-%H:%M:%S")
	destDir="$backupsDir/Back_\$dateExt"
	baseDir="$backupsDir/\$(ls "$backupsDir" | sort -t_ -k2 -g -r | head -n 1)"
	if [ ! -d "\$baseDir" ]; then
		exit 1
	fi

	tempf=\$(mktemp)
	tempDir=\$(mktemp -d)
	mkdir "\$destDir"
	cd "\$tempDir"
	gunzip -c "\$baseDir/backupstream.gz" | mbstream -x
	
	pathToBase=\$(realpath --relative-to="\$destDir" "\$baseDir")
	if [ -z "\$dataBases" ]; then
		backInfo="inc;\${pathToBase}\nfull\n\$dateForm"
		mariabackup --backup --incremental-basedir="\$tempDir" --user=root --stream=xbstream > "\$tempf"
	else
		backInfo="inc;\${pathToBase}\npartial;\${dataBases}\n\$dateForm"
		mariabackup --backup --incremental-basedir="\$tempDir" --databases="\$dataBases" --user=root --stream=xbstream > "\$tempf"
	fi
	if [ -s "\$tempf" ]; then #Si no esta vacio
		cat "\$tempf" | gzip > "\$destDir/backupstream.gz"
		echo -e "\$backInfo" > "\$destDir/backInfo"
		rm "\$tempf"
		rm -R "\$tempDir"
	else
		rm "\$tempf"
		rm -R "\$tempDir"
		rm -R "\$destDir"
		exit 1
	fi
	EOF

	chmod 744 "$backupsDir/schedIncPhy.sh"

	crontab -l > mycron
	echo "$mins $hours * $months $days $backupsDir/schedIncPhy.sh" >> mycron
	crontab mycron
	rm mycron

	echo ":: Tarea planificada con exito"
}

cleanCrontab(){
	echo ":: Se borraran todas las tareas de backup planificadas, ¿desea continuar? (S|N)"
	echo -n "-->"
	read resp
	case $resp in
		S|s)
		crontab -l | grep -v 'schedIncPhy\|schedPhy' > mycron
		crontab mycron
		rm mycron
		echo ":: Tareas borradas con exito"
		;;
		*)
		:
		;;
	esac
}


####INICIO SCRIPT

opt=-1
while (( $opt != 0 ))
do
	opt=-1
	while (( $opt < 0 || $opt > 6 ))
	do
		echo ":: Seleccione operacion:"
		echo "(1) Crear backup fisico"
		echo "(2) Crear backup fisico incremental"
		echo "(3) Restaurar backup"
		echo "(4) Planificar Backup fisico"
		echo "(5) Planificar Backup fisico incremental"
		echo "(6) Borrar tareas de backup"
		echo "(0) Salir"
		echo -n "-->"
		read opt
	done
	case $opt in
	    1)
	    makePhysicBackup
	    ;;
	    2)
	    makePhysicIncBackup
	    ;;
	    3)
	    restoreBackup
	    ;;
	    4)
	    schedulePhysicBackup
	    ;;
	    5)
	    schedulePhysicIncBackup
	    ;;
	    6)
		cleanCrontab
		;;
	    *) 
	    exit 0
	    ;;
	esac
done