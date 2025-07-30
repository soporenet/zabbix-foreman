#!/bin/bash
#
# Project: zabbix-foreman
# File: ForemanReportGen-json.sh
# Description: File for collecting stats
# Author: SoporeNet
# Email: admin@sopore.net
# Created: 2025-06-14
#

# Configuration Variables
LIFECYCLE_ENVS=("Team1" "Team2")
CONTENT_VIEWS=("Grafana_CV" "Nginx_CV")
REPOS=("1" "2")
SATELLITE=("lnxsat1.sopore.net")
CAPSULES=("capsule1.sopore.net")
SSH_USER="ansible"
DB_NAME="foreman"
DB_USER="foreman"
DB_PASS="psql"

# Health Check Thresholds (in days)
CONTENT_VIEW_PUBLISH_DAYS=2
LIFECYCLE_PROMOTE_DAYS=2
REPOSITORY_SYNC_DAYS=1

# Logging Setup
LOG_DIR="/jobs/cronlogs/satellite_health"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/satellite_health_${TIMESTAMP}.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Redirect all output to log file
exec > >(tee -a "$LOG_FILE") 2>&1

# Status Tracking
OVERALL_STATUS=0
FAILED_CHECKS=()

# Enhanced logging
log() {
    local message="$1"
    local log_only="${2:-false}"
    local timestamp=$(date +"%Y-%m-%d %T")

    # Always log to file
    echo -e "${timestamp} $message" >> "$LOG_FILE"

    # Conditionally log to terminal
    if [[ "$log_only" != "true" ]]; then
        echo -e "$message"
    fi
}

# Enhanced database query function
run_pg_query() {
    local query="$1"
    local context="$2"
    local log_query="${3:-true}"

    if [[ "$log_query" == "true" ]]; then
        log "Running query: $query" "true"
    fi

    result=$(sudo -u postgres psql -d "$DB_NAME" -t -c "$query" 2>&1)
    local status=$?

    if [[ "$log_query" == "true" ]]; then
        log "Query result: $result" "true"
    fi

    if [ $status -ne 0 ]; then
        log "DATABASE ERROR: $result" "true"
        log "QUERY FAILED: $query" "true"
        return 1
    fi

    if [[ -z "$result" || "$result" =~ "0 rows" ]]; then
        log "DATA NOT FOUND: $context" "true"
        log "QUERY RETURNED EMPTY: $query" "true"
        return 2
    fi

    echo "$result"
    return 0
}

# Health Check 1: Satellite Services
check_satellite_services() {
    log "===== [1] Satellite Services Health Check ====="
    local status=0
    local details=""

    if satellite-maintain service status -b; then
        log "SUCCESS: All Satellite services are running."
        details="All Satellite services are running"
        status=0
    else
        log "ERROR: One or more Satellite services are down!"
        FAILED_CHECKS+=("[1] Satellite Services")
        details="One or more Satellite services are down!"
        status=1
    fi

    # Add satellite service
    add_zabbix_item "services" "{#NAME}" "lnxsat1.sopore.net"
    add_zabbix_item "services" "COMPONENT" "lnxsat1.sopore.net"
    add_zabbix_item "services" "STATUS" "$status"
    add_zabbix_item "services" "DETAILS" "$details"
    save_current_zabbix_item "services"

    return $status
}

# Health Check 2: Capsule Services
check_capsule_services() {
    log "===== [2] Capsule Services Health Check ====="
    local status=0

    for capsule in "${CAPSULES[@]}"; do
        log "Checking $capsule..."
        local details=""
        local capsule_status=0

        if ssh -o StrictHostKeyChecking=no -l "$SSH_USER" "$capsule" "sudo satellite-maintain service status -b"; then
            log "SUCCESS: All services on $capsule are running."
            details="All services on $capsule are running"
            capsule_status=0
        else
            log "ERROR: Service failure detected on $capsule!"
            FAILED_CHECKS+=("[2] Capsule Services ($capsule)")
            details="Service failure detected on $capsule"
            capsule_status=1
            status=1
        fi

        # Add capsule service
        add_zabbix_item "services" "{#NAME}" "$capsule"
        add_zabbix_item "services" "COMPONENT" "$capsule"
        add_zabbix_item "services" "STATUS" "$capsule_status"
        add_zabbix_item "services" "DETAILS" "$details"
        save_current_zabbix_item "services"
    done

    return $status
}

# Health Check 3: Content View Publish Dates
check_content_views() {
    log "===== [3] Content View Publish Dates ====="
    local status=0

    for cv in "${CONTENT_VIEWS[@]}"; do
        log "Checking $cv..."
        query="
            SELECT
                cvv.id,
                cvv.created_at,
                cvh.status
            FROM katello_content_views AS cv
            JOIN katello_content_view_versions AS cvv ON cv.id = cvv.content_view_id
            JOIN katello_content_view_histories AS cvh ON cvv.id = cvh.katello_content_view_version_id
            WHERE cv.name = '$cv'
                AND cvh.katello_environment_id IS NULL
            ORDER BY cvv.created_at DESC
            LIMIT 1"

        result=$(run_pg_query "$query" "Content view $cv")
        version_id=$(echo "$result" | cut -d'|' -f1 | xargs)
        publish_date=$(echo "$result" | cut -d'|' -f2 | xargs)
        publish_status=$(echo "$result" | cut -d'|' -f3 | xargs)

        local cv_status=0
        local details=""

        if [[ -z "$version_id" ]]; then
            log "ERROR: $cv has no publish history!"
            FAILED_CHECKS+=("[3] Content View: $cv (no publish history)")
            cv_status=1
            details="$cv has no publish history!"
            status=1
        else
            # Convert timestamps to seconds for comparison
            publish_sec=$(date -d "$publish_date" +%s 2>/dev/null)
            days_ago_sec=$(date -d "$CONTENT_VIEW_PUBLISH_DAYS days ago" +%s)

            if [[ $publish_sec -ge $days_ago_sec ]] && [[ "$publish_status" == "successful" ]]; then
                log "SUCCESS: $cv has a successful publish within $CONTENT_VIEW_PUBLISH_DAYS days ($publish_date), version ($version_id)"
                cv_status=0
                details="$cv has a successful publish within $CONTENT_VIEW_PUBLISH_DAYS days"
            else
                if [[ "$publish_status" != "successful" ]]; then
                    log "ERROR: $cv's latest publish (version $version_id) has status: $publish_status!"
                    cv_status=1
                    details="$cv's latest publish has status: $publish_status"
                else
                    log "ERROR: $cv's latest publish is older than $CONTENT_VIEW_PUBLISH_DAYS days ($publish_date)!"
                    cv_status=1
                    details="$cv's latest publish is older than $CONTENT_VIEW_PUBLISH_DAYS days"
                fi
                FAILED_CHECKS+=("[3] Content View: $cv")
                status=1
            fi
        fi

        # Add content view item
        add_zabbix_item "content_views" "{#NAME}" "$cv"
        add_zabbix_item "content_views" "COMPONENT" "$cv"
        add_zabbix_item "content_views" "STATUS" "$cv_status"
        add_zabbix_item "content_views" "PUBLISH_DATE" "$publish_date"
        add_zabbix_item "content_views" "DETAILS" "$details"
        save_current_zabbix_item "content_views"
    done

    return $status
}

# Health Check 4: Lifecycle Environment Promotions
check_lifecycle_environments() {
    log "===== [4] Lifecycle Environment Promotions ====="
    local status=0

    for env in "${LIFECYCLE_ENVS[@]}"; do
        log "Checking $env..."
        env_failed=0
        local env_status=0
        local details=""

        # Query to get content views and their latest promoted version
        query="
            SELECT
                cv.name AS content_view_name,
                cvv.id AS version_id,
                cvv.created_at AS publish_date,
                cvh.created_at AS promote_date,
                cvh.status AS promote_status
            FROM katello_content_view_environments cve
            JOIN katello_environments e ON e.id = cve.environment_id
            JOIN katello_content_view_versions cvv ON cvv.id = cve.content_view_version_id
            JOIN katello_content_views cv ON cv.id = cvv.content_view_id
            JOIN katello_content_view_histories cvh ON (
                cvh.katello_content_view_version_id = cvv.id
                AND cvh.katello_environment_id = e.id
                AND cvh.action = 2
            )
            WHERE e.name = '$env'
            ORDER BY cv.name, cvh.created_at DESC"

        # Execute query and process results
        while IFS='|' read -r cv_name version_id publish_date promote_date promote_status; do
            # Clean up whitespace
            cv_name=$(echo "$cv_name" | xargs)
            version_id=$(echo "$version_id" | xargs)
            publish_date=$(echo "$publish_date" | xargs)
            promote_date=$(echo "$promote_date" | xargs)
            promote_status=$(echo "$promote_status" | xargs)

            # Convert timestamps to seconds
            promote_sec=$(date -d "$promote_date" +%s 2>/dev/null)
            days_ago_sec=$(date -d "$LIFECYCLE_PROMOTE_DAYS days ago" +%s)

            # Check if promotion was recent and successful
            if [[ $promote_sec -ge $days_ago_sec ]] && [[ "$promote_status" == "successful" ]]; then
                log "  SUCCESS: $cv_name (version $version_id) promoted successfully on $promote_date"
            else
                if [[ "$promote_status" != "successful" ]]; then
                    log "  ERROR: $cv_name (version $version_id) promotion FAILED! Status: $promote_status"
                else
                    log "  ERROR: $cv_name (version $version_id) promotion too old! Date: $promote_date"
                fi
                env_failed=1
            fi
        done < <(run_pg_query "$query" "Lifecycle env $env")

        # Check if we found any content views for this environment
        if [[ -z "$(run_pg_query "$query" "Lifecycle env $env" "false")" ]]; then
            log "  WARNING: No content views found in $env environment"
            env_failed=1
        fi

        # Update status
        if [[ $env_failed -eq 1 ]]; then
            log "ERROR: $env has issues with content view promotions!"
            FAILED_CHECKS+=("[4] Lifecycle Environment: $env")
            env_status=1
            details="$env has issues with content view promotions!"
            status=1
        else
            log "SUCCESS: $env has recent successful promotions for all content views."
            env_status=0
            details="$env has recent successful promotions for all content views"
        fi

        # Add lifecycle environment item
        add_zabbix_item "lifecycle_environments" "{#NAME}" "$env"
        add_zabbix_item "lifecycle_environments" "COMPONENT" "$env"
        add_zabbix_item "lifecycle_environments" "STATUS" "$env_status"
        add_zabbix_item "lifecycle_environments" "DETAILS" "$details"
        save_current_zabbix_item "lifecycle_environments"
    done

    return $status
}

# Health Check 6: Repository Sync Status (Enhanced)
check_repository_sync() {
    log "===== [6] Repository Sync Status ====="
    local status=0
    local repo_list=()

    # Build repository list from Content Views
    for cv in "${CONTENT_VIEWS[@]}"; do
        query="
            SELECT DISTINCT kr.id
            FROM katello_content_views kcv
            JOIN katello_content_view_repositories kcvr ON kcv.id = kcvr.content_view_id
            JOIN katello_repositories kr ON kcvr.repository_id = kr.id
            WHERE kcv.name = '$cv'"
        cv_repos=$(run_pg_query "$query" "Content view $cv repos")
        repo_list+=($cv_repos)
    done

    # Process each repository
    for repo_id in "${repo_list[@]}"; do
        # Clean repo_id
        repo_id=$(echo "$repo_id" | xargs)
        log "Checking Repository ID $repo_id..."

        # Get repository details
        repo_query="
            SELECT krr.name, kp.name, t.name
            FROM katello_root_repositories krr
            JOIN katello_products kp ON krr.product_id = kp.id
            JOIN taxonomies t ON kp.organization_id = t.id
            WHERE krr.id = $repo_id"
        repo_details=$(run_pg_query "$repo_query" "Repo $repo_id details")

        if [[ -z "$repo_details" ]]; then
            log "ERROR: Repository $repo_id not found!" "true"
            FAILED_CHECKS+=("[6] Repository $repo_id (not found)")
            status=1
            continue
        fi

        # Parse repository details
        IFS='|' read -r repo_name product_name org_name <<< "$repo_details"
        repo_name=$(echo "$repo_name" | xargs)
        product_name=$(echo "$product_name" | xargs)
        org_name=$(echo "$org_name" | xargs)

        local repo_status=0
        local details=""
        local last_sync="N/A"

        # Form action string pattern
        action_pattern="Synchronize repository ''$repo_name''; product ''$product_name''; organization ''$org_name''"

        # Find latest successful sync
        goldfinger_query="
            SELECT id, ended_at
            FROM foreman_tasks_tasks
            WHERE label = 'Actions::Katello::Repository::Sync'
                AND action = '$action_pattern'
                AND state = 'stopped'
                AND result = 'success'
            ORDER BY ended_at DESC
            LIMIT 1"
        goldfinger_result=$(run_pg_query "$goldfinger_query" "Repo $repo_id goldfinger")

        if [[ -z "$goldfinger_result" ]]; then
            log "ERROR: Repository $repo_id ($repo_name) has no successful sync history!" "true"
            FAILED_CHECKS+=("[6] Repository $repo_id ($repo_name) - no successful sync")
            repo_status=1
            details="$repo_name has no successful sync history"
            status=1
        else
            # Parse GOLDFINGER details
            IFS='|' read -r gf_task_id gf_ended_at <<< "$goldfinger_result"
            gf_task_id=$(echo "$gf_task_id" | xargs)
            gf_ended_at=$(echo "$gf_ended_at" | xargs)
            last_sync="$gf_ended_at"
            gf_ended_sec=$(date -d "$gf_ended_at" +%s 2>/dev/null)
            sync_days_ago_sec=$(date -d "$REPOSITORY_SYNC_DAYS days ago" +%s)

            # Check GOLDFINGER age
            if [[ $gf_ended_sec -lt $sync_days_ago_sec ]]; then
                log "ERROR: Repository $repo_id ($repo_name) last successful sync is older than $REPOSITORY_SYNC_DAYS days ($gf_ended_at)" "true"
                FAILED_CHECKS+=("[6] Repository $repo_id ($repo_name) - sync too old")
                repo_status=1
                details="$repo_name last sync is older than $REPOSITORY_SYNC_DAYS days"
                status=1
            else
                # Check for failed syncs after GOLDFINGER
                failed_query="
                    SELECT COUNT(*)
                    FROM foreman_tasks_tasks
                    WHERE label = 'Actions::Katello::Repository::Sync'
                        AND action = '$action_pattern'
                        AND state = 'stopped'
                        AND result != 'success'
                        AND ended_at > '$gf_ended_at'"
                failed_count=$(run_pg_query "$failed_query" "Repo $repo_id failed syncs")

                if [[ $failed_count -gt 0 ]]; then
                    log "ERROR: Repository $repo_id ($repo_name) has $failed_count failed syncs since last success ($gf_ended_at)" "true"
                    FAILED_CHECKS+=("[6] Repository $repo_id ($repo_name) - has failed syncs after last success")
                    repo_status=1
                    details="$repo_name has $failed_count failed syncs since last success"
                    status=1
                else
                    # Check for running syncs
                    running_query="
                        SELECT COUNT(*)
                        FROM foreman_tasks_tasks
                        WHERE label = 'Actions::Katello::Repository::Sync'
                            AND action = '$action_pattern'
                            AND state = 'running'"
                    running_count=$(run_pg_query "$running_query" "Repo $repo_id running syncs")

                    if [[ $running_count -gt 0 ]]; then
                        log "WARNING: Repository $repo_id ($repo_name) has sync in progress" "true"
                        log "WARNING: Sync in progress for $repo_name, but last successful sync was recent ($gf_ended_at)"
                        repo_status=0
                        details="Sync in progress for $repo_name"
                    else
                        log "SUCCESS: Repository $repo_id ($repo_name) sync status healthy (last sync: $gf_ended_at)" "true"
                        log "SUCCESS: Repository $repo_name synced recently ($gf_ended_at)"
                        repo_status=0
                        details="$repo_name synced recently"
                    fi
                fi
            fi
        fi

        # Add repository item
        add_zabbix_item "repositories" "{#NAME}" "$repo_name"
        add_zabbix_item "repositories" "COMPONENT" "$repo_name"
        add_zabbix_item "repositories" "STATUS" "$repo_status"
        add_zabbix_item "repositories" "LAST_SYNC" "$last_sync"
        add_zabbix_item "repositories" "DETAILS" "$details"
        save_current_zabbix_item "repositories"
    done

    return $status
}

# Zabbix LLD Data Collection
declare -A ZABBIX_ITEMS
declare -A ZABBIX_COMPONENTS

# Initialize Zabbix data structure
init_zabbix_data() {
    ZABBIX_COMPONENTS=(
        ["services"]=""
        ["repositories"]=""
        ["content_views"]=""
        ["lifecycle_environments"]=""
    )
    ZABBIX_ITEMS=()
}

# Enhanced Zabbix data collection
add_zabbix_item() {
    local type="$1"
    local key="$2"
    local value="$3"

    # Escape double quotes
    value=${value//\"/\\\"}

    if [ -z "${ZABBIX_ITEMS[$type]}" ]; then
        ZABBIX_ITEMS[$type]="\"$key\":\"$value\""
    else
        ZABBIX_ITEMS[$type]+=", \"$key\":\"$value\""
    fi
}

# Save current item and add to component list
save_current_zabbix_item() {
    local type="$1"

    if [ -n "${ZABBIX_ITEMS[$type]}" ]; then
        local item_json="{ ${ZABBIX_ITEMS[$type]} }"

        if [ -z "${ZABBIX_COMPONENTS[$type]}" ]; then
            ZABBIX_COMPONENTS[$type]="$item_json"
        else
            ZABBIX_COMPONENTS[$type]+=", $item_json"
        fi

        # Reset items for this type
        unset ZABBIX_ITEMS[$type]
    fi
}

# Generate Zabbix LLD JSON
generate_zabbix_json() {
    local metadata_time=$(date +"%Y-%m-%d %H:%M:%S.635687")
    local json="{"
    json+="\"metadata\": { \"generation_time\": \"$metadata_time\" },"

    # Add each component type
    local first=true
    for type in "${!ZABBIX_COMPONENTS[@]}"; do
        if [ -n "${ZABBIX_COMPONENTS[$type]}" ]; then
            if [ "$first" = false ]; then
                json+=","
            fi
            json+="\"$type\": [${ZABBIX_COMPONENTS[$type]}]"
            first=false
        fi
    done

    json+="}"
    echo "$json"
}

# Save Zabbix JSON to file
save_zabbix_json() {
    # Save any remaining unsaved items
    for type in "${!ZABBIX_ITEMS[@]}"; do
        if [ -n "${ZABBIX_ITEMS[$type]}" ]; then
            save_current_zabbix_item "$type"
        fi
    done

    local json_file="${LOG_DIR}/zabbix_lld.json"
    generate_zabbix_json | jq . > "$json_file"
    log "Zabbix LLD JSON saved to: $json_file" "true"
}

# Initialize Zabbix data
init_zabbix_data

# Execute Checks
check_satellite_services || OVERALL_STATUS=1
check_capsule_services || OVERALL_STATUS=1
check_content_views || OVERALL_STATUS=1
check_lifecycle_environments || OVERALL_STATUS=1
check_repository_sync || OVERALL_STATUS=1

# Save Zabbix JSON
save_zabbix_json

# Final Summary
log "===== HEALTH CHECK SUMMARY ====="
if [[ $OVERALL_STATUS -eq 0 ]]; then
    log "ALL CHECKS PASSED"
else
    log "FAILED CHECKS:"
    printf '  %s\n' "${FAILED_CHECKS[@]}"
fi

log "Log saved to: $LOG_FILE"

exit $OVERALL_STATUS

