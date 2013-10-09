#!/bin/bash
#
# Synkhole is a wrapper script to ease the creation of incremental backups. 
# It has no external dependencies, relying only on rsync and coreutils for 
# hardlinking and updating local snapshots. 
#
# @nunogt

. conf/synkhole.conf

log() {                                                                         
    echo "`date --iso-8601=seconds` $1" | tee -a $LOGFILE                       
}   

check_exit_status() {
    if [ "$1" != "0" ] ; then
        echo "Process exited with error code: $1"
        exit $1
    fi
}

resolve_links_unix() {
    PRG="$0"
    while [ -h "$PRG" ] ; do
        ls=`ls -ld "$PRG"`
        link=`expr "$ls" : '.*-> \(.*\)$'`
        if expr "$link" : '/.*' > /dev/null; then
            PRG="$link"
        else
            PRG=`dirname "$PRG"`/"$link"
        fi
    done
    SYNKHOLE_HOME=`dirname "$PRG"`
}

resolve_links_linux() {
    PRG="`readlink -f $0`"
    SYNKHOLE_HOME=`dirname "$PRG"`
}

resolve_links(){
    # GNU coreutils makes this easy, so let's test for that
    case "`uname`" in
        Linux*) resolve_links_linux;;
        *) resolve_links_unix;;
    esac 
}

bootstrap() {
    resolve_links
    # set up logging
    LOGFILE="$SYNKHOLE_HOME/log/synkhole.log"
    if [ ! -d "`dirname $LOGFILE`" ] ; then
        mkdir -p `dirname $LOGFILE`
        check_exit_status $?
    fi 
    log "This is $PRG at `hostname -f`"
    # test for valid backup sources
    for i in $BACKUP_DIR ; do
        if [ ! -d "$i" ] ; then
            log "Backup source $i doesn't seem to exist. Aborting."
            log "Please review $SYNKHOLE_HOME/conf/synkhole.conf"
            check_exit_status 1
        fi 
    done
    # test for valid backup destination directory
    STORAGE_DIR="$STORAGE_DIR/`hostname -f`"
    if [ ! -d "$STORAGE_DIR" ] ; then
        log "Target path $STORAGE_DIR doesn't exist. Attempting to create..."
        mkdir -p $STORAGE_DIR
        check_exit_status $?
        log "Success."
    fi
    TIMESTAMP="`date +%s`"
    CURRENT="$TIMESTAMP"
    PREVIOUS="`ls -rt1 $STORAGE_DIR/ | tail -n 1`"
    WORKING_COPY="$STORAGE_DIR/$CURRENT.synkhole" 

    log "Boostrap completed."
}

hardlink() {
    log "Hardlinking $PREVIOUS into $CURRENT..."
    for i in $STORAGE_DIR/$PREVIOUS/* ; do
        cp -al $i $WORKING_COPY/
        check_exit_status $?
    done
    log "New working copy hardlinked successfully."
}

synchronize() {
    log "Updating current working copy..."
    for i in $BACKUP_DIR ; do
        rsync -aRH --delete $i $WORKING_COPY/
        check_exit_status $?
        log "Backup source $i successfully synchronized."
    done
    log "Everything is up to date."
}

deref_dirs() {
    log "Dereferencing source directories..."
    deref=()
    for i in $BACKUP_DIR ; do
        deref+=("`readlink -f $i`")
    done
    BACKUP_DIR="`echo ${deref[@]}`"
}

check_consistency() {
    for i in $STORAGE_DIR/* ; do
        if [[ "$i" == *synkhole* ]] ; then
            log "Target path contains interrupted or in-progress backup $i"
            log "Synkhole will not continue until this is manually reviewed."
            check_exit_status 2
        fi
    done
    deref_dirs
}

cleanup() {                                                                     
    log "Performing cleanup..."                                                 
    mv $WORKING_COPY $STORAGE_DIR/$CURRENT                                      
    check_exit_status $?                                                        
    outdated=()                                                                 
    invalid=()
    # a bit of voodoo to determine the treshold for removal                     
    OLDEST_DATE=$(date +%s --date "`date --iso-8601` -$DISCARD_MAX_DAYS day")        
    for i in $STORAGE_DIR/* ; do                                                
        PARSED_DATE="$(date --date @`basename $i` > /dev/null 2>&1)"
        if [ "$?" == "0" ] ; then
            if [ "`basename $i`" -lt "$OLDEST_DATE" ] ; then                                        
                log "$i is older than the configured maximum treshold."             
                log "Scheduling for removal."                                       
                outdated+=("$i")                                                    
            fi                                                                      
        else
            log "Can't tell if backup $i is valid."
            log "Please review."
            invalid+=("$i")
        fi
    done                                                                        
    for o in "${outdated[@]}" ; do
        log "Removing $o"
        rm -rf $o
    done
}       

backup() {
    log "Initiating backup procedure"
    log "Attempting to create new working copy..."
    mkdir -p $WORKING_COPY
    check_exit_status $?
    log "Success."
    log "Determining previous backup..."
    if [ ! -z "$PREVIOUS" ] ; then
        if [ -d "$STORAGE_DIR/$PREVIOUS" ] ; then
            log "Previous backup found at $STORAGE_DIR/$PREVIOUS"
            hardlink
        fi
    else
        log "Previous backup not found. Assuming first run..."
    fi
    synchronize
}

summary() {
    log "Backup completed."
    log "Summary:"
    if [ "${#outdated[@]}" -gt "0" ] ; then
        log "The following outdated backups were purged:"
        log "`echo ${outdated[@]}`"
    fi
    if [ "${#invalid[@]}" -gt "0" ] ; then
        log "The following backups are invalid and need your attention:"
        log "`echo ${invalid[@]}`"
    fi
    log "Latest backup is: $STORAGE_DIR/$CURRENT"
}

bootstrap
check_consistency
backup
cleanup
summary
