#!/bin/bash

# Branch Database State Switcher
VERSION=1.5

ACTION_TYPE=$1
if [ -z "$ACTION_TYPE" ]; then
  echo "Please provide an action type as the first argument (version, backup, restore, list)."
  echo "Refer to the readme.md for more information."
  echo "Exiting from 'Branch Database State Switcher v$VERSION...'"
  exit
fi

# ---------------------------------------------------------------------- #
# Check script version via switches "--version" or "-v"
# ---------------------------------------------------------------------- #
if [ "$ACTION_TYPE" == "-v" ] || [ "$ACTION_TYPE" == "--version" ]; then
    echo "Branch database state switcher v$VERSION"
    exit
fi

# ---------------------------------------------------------------------- #
# Check if current directory is a git repository
# ---------------------------------------------------------------------- #
if ! git rev-parse --is-inside-work-tree > /dev/null; then
    echo "Current directory is not a git repository."
    echo "Please run the script inside a git repository."
    echo "Exiting from 'Branch Database State Switcher v$VERSION...'"
    exit
fi


# ---------------------------------------------------------------------- #
# Check if config file is present, otherwise ask the user to create it
# ---------------------------------------------------------------------- #
if [ ! -f "./.env" ]; then
    echo "Config file '.env' not found."
    echo "Please create a '.env' file with the following variables:"
    echo "BDS_DOCKER_CONTAINER_ID='your docker container id that runs the database'"
    echo "BDS_DB_NAMES='comma separated list of your database names'"
    echo "BDS_DB_USER='your database's username'"
    echo "BDS_DB_PASSWORD='your database's password'"
    echo "Don't forget to add '.env' to your .gitignore file."
    echo "Exiting from 'Branch Database State Switcher v$VERSION...'"
    exit
fi

# Load variables from the .env file
BDS_DOCKER_CONTAINER_ID=$(grep BDS_DOCKER_CONTAINER_ID ./.env | cut -d '=' -f2)
BDS_DB_NAMES=$(grep BDS_DB_NAMES ./.env | cut -d '=' -f2)
BDS_DB_USER=$(grep BDS_DB_USER ./.env | cut -d '=' -f2)
BDS_DB_PASSWORD=$(grep BDS_DB_PASSWORD ./.env | cut -d '=' -f2)
BDS_SAFE_RESTORE_MODE=$(grep BDS_SAFE_RESTORE_MODE ./.env | cut -d '=' -f2)
# Set default value for BDS_SAFE_RESTORE_MODE=true if not provided
if [ -z "$BDS_SAFE_RESTORE_MODE" ]; then BDS_SAFE_RESTORE_MODE="true"; fi;

# Convert BDS_DB_NAMES to an array
IFS=',' read -r -a DB_NAME_ARRAY <<< "$BDS_DB_NAMES"

echo ""
echo "--------- Configurations ---------"
echo "Container ID(BDS_DOCKER_CONTAINER_ID): '$BDS_DOCKER_CONTAINER_ID'"
echo "Database names(BDS_DB_NAMES): '${DB_NAME_ARRAY[@]}'"
echo "Database username(BDS_DB_USER): '$BDS_DB_USER'"
echo "Database password(BDS_DB_PASSWORD): '$BDS_DB_PASSWORD'"
echo "Safe restore mode(BDS_SAFE_RESTORE_MODE): '$BDS_SAFE_RESTORE_MODE'"
echo "------------------------"
echo ""

# ---------------------------------------------------------------------- #
# Check if the docker image is running
# ---------------------------------------------------------------------- #
if ! docker ps | grep $BDS_DOCKER_CONTAINER_ID > /dev/null; then
    echo "Docker image '$BDS_DOCKER_CONTAINER_ID' is not running."
    echo "Please start the docker image and try again."
    echo "Exiting from 'Branch Database State Switcher v$VERSION...'"
    exit
fi

# ---------------------------------------------------------------------- #
# Check if the database is accessible
# ---------------------------------------------------------------------- #
for DB_NAME in "${DB_NAME_ARRAY[@]}"; do
    if ! docker exec $BDS_DOCKER_CONTAINER_ID psql -U $BDS_DB_USER -d $DB_NAME -c "SELECT version();" > /dev/null; then
        echo "Failed to connect to the database '$DB_NAME'."
        echo "Please check the database name and user in the config file."
        echo "Exiting from 'Branch Database State Switcher v$VERSION...'"
        exit
    fi
done

# ---------------------------------------------------------------------- #
# Check if the BACKUP_DIR is present inside the container
# ---------------------------------------------------------------------- #
BACKUP_DIR="/bds_backups"
if ! docker exec $BDS_DOCKER_CONTAINER_ID [ -d $BACKUP_DIR ]; then
    if docker exec $BDS_DOCKER_CONTAINER_ID mkdir -p $BACKUP_DIR; then
        echo "Backup directory '$BACKUP_DIR' created successfully."
    else
        echo "Failed to create backup directory."
    fi
else
    echo "Backup directory: '$BACKUP_DIR'"
fi

# ---------------------------------------------------------------------- #
# List all backups inside the container
# ---------------------------------------------------------------------- #
if [ "$ACTION_TYPE" == "--list" ] || [ "$ACTION_TYPE" == "-l" ]; then
    # Perform list all backups operation
    echo "$BACKUP_DIR:"
    if output=$(docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "ls -l $BACKUP_DIR" 2>&1); then
        echo "$output"
    else
        echo "Failed to list all backups inside the container. Error: $output"
    fi
    exit
fi

# ---------------------------------------------------------------------- #
# Check if the BACKUP_NAME name is provided as the second argument
# ---------------------------------------------------------------------- #
if [ "$ACTION_TYPE" == "backup" ] || [ "$ACTION_TYPE" == "backup-local" ] || [ "$ACTION_TYPE" == "restore" ] || [ "$ACTION_TYPE" == "restore-local" ] || [ "$ACTION_TYPE" == "delete" ]; then
    if [ -z "$2" ]; then
        # If not provided, generate backup name based on branch name
        BACKUP_NAME="$(git rev-parse --abbrev-ref HEAD | sed 's|/|_|g')"
    else
        # If provided, use the second argument as the backup name
        BACKUP_NAME=$2
    fi
fi
echo "Backup name: '$BACKUP_NAME'"

# ---------------------------------------------------------------------- #
# Ask the user to confirm the action
# ---------------------------------------------------------------------- #
echo ""
echo "Do you want to run '$ACTION_TYPE' process for your DB on '$BACKUP_NAME' branch? (y/n)"
read answer
if [ "$answer" != "y" ]; then
    echo "Exiting..."
    exit
fi

echo "===================================================================="
echo "Starting database $ACTION_TYPE process on the docker image itself"
echo "===================================================================="
echo ""

# ---------------------------------------------------------------------- #
# Perform Actions
# ---------------------------------------------------------------------- #
###### Backup Inside Docker ######
if [ "$ACTION_TYPE" == "backup" ]; then
    # Perform backup operation
    for DB_NAME in "${DB_NAME_ARRAY[@]}"; do
        if docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "pg_dump -Fc -U $BDS_DB_USER -d $DB_NAME > $BACKUP_DIR/$DB_NAME-$BACKUP_NAME"; then
            echo "Backup process for '$DB_NAME' completed successfully inside docker at '$BACKUP_DIR/$DB_NAME-$BACKUP_NAME'."
        else
            echo "Failed to create backup file for '$DB_NAME' inside docker."
        fi
    done
###### Backup Locally in the current working directory ######
elif [ "$ACTION_TYPE" == "backup-local" ]; then
    # Perform local backup operation
    for DB_NAME in "${DB_NAME_ARRAY[@]}"; do
        if docker exec -i $BDS_DOCKER_CONTAINER_ID pg_dump -Fc -U $BDS_DB_USER -d $DB_NAME > "./$DB_NAME-$BACKUP_NAME"; then
            echo "Local backup process for '$DB_NAME' completed successfully at './$DB_NAME-$BACKUP_NAME'."
        else
            echo "Failed to create local backup file for '$DB_NAME' at './$DB_NAME-$BACKUP_NAME'."
        fi
    done
###### Restore DB From Backup files Inside Docker ######
elif [ "$ACTION_TYPE" == "restore" ]; then
    for DB_NAME in "${DB_NAME_ARRAY[@]}"; do
        # Check if the backup file exists
        if ! docker exec $BDS_DOCKER_CONTAINER_ID [ -f $BACKUP_DIR/$DB_NAME-$BACKUP_NAME ]; then
            echo "Backup file '$BACKUP_DIR/$DB_NAME-$BACKUP_NAME' not found inside the container."
            echo "Exiting from 'Branch Database State Switcher v$VERSION...'"
            exit
        fi

        # Check if safe restore mode is not false
        if [ "$BDS_SAFE_RESTORE_MODE" != "false" ]; then
            # Get a backup with safemode extension
            if docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "pg_dump -Fc -U $BDS_DB_USER -d $DB_NAME > $BACKUP_DIR/$DB_NAME-$BACKUP_NAME.safemode"; then
                echo "Created a safemode backup for '$DB_NAME' before restoring: '$BACKUP_DIR/$DB_NAME-$BACKUP_NAME.safemode'."
            else
                echo "Failed to create safemode backup file for '$DB_NAME' inside docker."
                exit
            fi
        else
            echo "Taking backup for safemode before restore operation is disabled (BDS_SAFE_RESTORE_MODE=false)"
        fi

        # First, drop all tables in the database
        if docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "psql -U $BDS_DB_USER -d $DB_NAME -t <<EOF | psql -U $BDS_DB_USER -d $DB_NAME
SELECT 'DROP TABLE IF EXISTS \"' || tablename || '\" CASCADE;' FROM pg_tables WHERE schemaname = 'public';
EOF" > /dev/null 2>&1 && docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "psql -U $BDS_DB_USER -d $DB_NAME -c 'SET session_replication_role = replica;'" > /dev/null 2>&1; then
            echo "Dropped all tables inside the database '$DB_NAME' for clean restore."
            if docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "pg_restore --clean --if-exists -U $BDS_DB_USER -d $DB_NAME $BACKUP_DIR/$DB_NAME-$BACKUP_NAME" > /dev/null 2>&1 && docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "psql -U $BDS_DB_USER -d $DB_NAME -c 'SET session_replication_role = DEFAULT;'" > /dev/null 2>&1; then
                echo "Restore process for '$DB_NAME' completed successfully inside docker from '$BACKUP_DIR/$DB_NAME-$BACKUP_NAME'."
            else
                echo "Failed to restore backup file for '$DB_NAME' or re-enable FK checks."
            fi
        else
            echo "Failed to drop tables inside the database '$DB_NAME' for a clean restore."
        fi
    done
###### Restore DB From Local Backup files ######
elif [ "$ACTION_TYPE" == "restore-local" ]; then
    for DB_NAME in "${DB_NAME_ARRAY[@]}"; do
        # Check if the backup file exists locally
        if [ ! -f "./$DB_NAME-$BACKUP_NAME" ]; then
            echo "Local backup file './$DB_NAME-$BACKUP_NAME' not found."
            echo "Exiting from 'Branch Database State Switcher v$VERSION...'"
            exit
        fi

        # Check if safe restore mode is not false
        if [ "$BDS_SAFE_RESTORE_MODE" != "false" ]; then
            # Get a backup with safemode extension
            if docker exec -t $BDS_DOCKER_CONTAINER_ID pg_dump -Fc -U $BDS_DB_USER -d $DB_NAME > ./$DB_NAME-$BACKUP_NAME.safemode; then
                echo "Created a safemode backup for '$DB_NAME' locally before restoring: './$DB_NAME-$BACKUP_NAME.safemode'."
            else
                echo "Failed to create safemode backup for '$DB_NAME'."
                exit
            fi
        else
            echo "Taking backup for safemode before restore operation is disabled (BDS_SAFE_RESTORE_MODE=false)"
        fi

        # First, drop all tables in the database
        if docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "psql -U $BDS_DB_USER -d $DB_NAME -t <<EOF | psql -U $BDS_DB_USER -d $DB_NAME
SELECT 'DROP TABLE IF EXISTS \"' || tablename || '\" CASCADE;' FROM pg_tables WHERE schemaname = 'public';
EOF" > /dev/null 2>&1 && docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "psql -U $BDS_DB_USER -d $DB_NAME -c 'SET session_replication_role = replica;'" > /dev/null 2>&1; then
            echo "Dropped all tables inside the database '$DB_NAME' for clean restore."
            ######### Restore the backup file from local backup #########
            if docker exec -i $BDS_DOCKER_CONTAINER_ID pg_restore --clean --if-exists -U $BDS_DB_USER -d $DB_NAME < "$DB_NAME-$BACKUP_NAME" > /dev/null 2>&1 && docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "psql -U $BDS_DB_USER -d $DB_NAME -c 'SET session_replication_role = DEFAULT;'" > /dev/null 2>&1; then
                echo "Restore process for '$DB_NAME' completed successfully from local backup './$DB_NAME-$BACKUP_NAME'."
            else
                echo "Failed to restore backup file for '$DB_NAME' or re-enable FK checks."
            fi
        else
            echo "Failed to drop tables inside the database '$DB_NAME' for a clean restore."
        fi
    done
###### Delete a specific Backup file Inside Docker ######
elif [ "$ACTION_TYPE" == "delete" ]; then
    # Perform delete specific backup operation
    for DB_NAME in "${DB_NAME_ARRAY[@]}"; do
        if docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "rm $BACKUP_DIR/$DB_NAME-$BACKUP_NAME"; then
            echo "Deleted backup '$BACKUP_DIR/$DB_NAME-$BACKUP_NAME' inside the container."
        else
            echo "Failed to delete backup '$BACKUP_DIR/$DB_NAME-$BACKUP_NAME' inside the container."
        fi
    done
###### Delete all backup files Inside Docker ######
elif [ "$ACTION_TYPE" == "delete-all" ]; then
    # Perform delete all backups operation
    if docker exec -t $BDS_DOCKER_CONTAINER_ID bash -c "rm -R $BACKUP_DIR"; then
        echo "Deleted all backups inside the container."
    else
        echo "Failed to delete all backups inside the container."
    fi
else
    # Handle invalid action type
    echo "Invalid action type. Please provide either 'list', 'backup', 'restore', 'delete', or 'delete-all' as the first argument."
fi
