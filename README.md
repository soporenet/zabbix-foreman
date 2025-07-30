# zabbix-foreman

Zabbix Template for monitoring a Foreman host.

# Zabbix Foreman Monitoring Template

A comprehensive Zabbix template for monitoring Foreman/Katello infrastructure, including Services, Content Views, Lifecycle Environments, and Repository sync status. Since Redhat Satellite is based on foreman, this template can also be used for Satellite/Capsules.

## Features

- **Multi-component monitoring**: Tracks health of all critical Foreman components
- **Automated discovery**: Dynamic discovery of monitored elements
- **Detailed dashboards**: Pre-built visualizations for quick status assessment
- **Threshold-based alerts**: Configurable alerting for stale or failed components
- **Health percentage metrics**: Overall health indicators for each component type

## Requirements

- Zabbix Server 7.2 or higher
- Foreman/Katello installation with PostgreSQL database
- SSH access to Satellite and Capsule servers
- `jq` package installed on the Satellite server
- Ansible user with sudo privileges on Capsules

## Installation

1. **Import the template**:
   - Navigate to Zabbix web interface → Templates → Import
   - Upload `SoporeNet_Foreman_Monitoring_Template.json`

2. **Deploy the data collection script**:
   ```bash
   cp SoporeNet_ForemanReportGen-json.sh /usr/local/bin/SoporeNet_ForemanReportGen-json.sh
   chmod +x /usr/local/bin/SoporeNet_ForemanReportGen-json.sh
   ``` 
3. **Configure cron job (run every 10 minutes)**:
   ```bash
   echo "*/10 * * * * root /usr/local/bin/SoporeNet_ForemanReportGen-json.sh" > /etc/cron.d/SoporeNet_ForemanReportGen-json
    ```
4. **Assign template to your Foreman host in Zabbix**

## Configuration

Edit the script variables in SoporeNet_ForemanReportGen-json.sh to match your environment:
   ```bash
   # Configuration Variables
   LIFECYCLE_ENVS=("Team1" "Team2")              # Your lifecycle environments
   CONTENT_VIEWS=("Grafana_CV" "Nginx_CV")       # Content Views to monitor
   SATELLITE=("lnxsat1.sopore.net")              # Satellite FQDN
   CAPSULES=("capsule1.sopore.net")              # Capsule servers
   SSH_USER="ansible"                            # SSH user for capsule checks
   DB_NAME="foreman"                             # Foreman database name
   DB_USER="foreman"                             # Database user
   DB_PASS="psql"                                # Database password

   # Health Check Thresholds (in days)
   CONTENT_VIEW_PUBLISH_DAYS=2                   # Max age for CV publishes
   LIFECYCLE_PROMOTE_DAYS=2                      # Max age for promotions
   REPOSITORY_SYNC_DAYS=1                        # Max age for repo syncs
   ```

## Collected Metrics

1. **Satellite Services**
- Service status (running/stopped)
- Detailed status information

2. **Capsule Services**
- Service status for each capsule
- Connection status

3. **Content Views**
- Last publish date
- Publish status (success/failure)
- Age of last publish

4. **Lifecycle Environments**
- Promotion status for each environment
- Promotion dates
- Content view versions in each environment

5. **Repositories**
- Last sync date
- Sync status (success/failure)
- Failed sync attempts since last success
- Currently running syncs

## Zabbix Items Overview

**Main Items**
- foreman.health.data: Raw JSON health data
- foreman.health.generation_time_epoch: Data freshness check

**Percentage Health Metrics**
- satellite.health.svc.healthypercentage: % of healthy services
- satellite.health.repo.healthypercentage: % of synced repositories
- satellite.health.cv.healthypercentage: % of up-to-date content views
- satellite.health.le.healthypercentage: % of healthy lifecycle environments

**Discovery Rules**
- Service Discovery: foreman.health.svc.discovery
- Repository Discovery: foreman.health.repo.discovery
- Content-View Discovery: foreman.health.cv.discovery
- Lifecycle-Environment Discovery: foreman.health.le.discovery

**Dashboards**
- Overview Dashboard:
-- Active problems widget
-- Health percentage graphs for all components
-- Quick status overview

- Component-specific Dashboards:
-- Services: Detailed status graphs
-- Repositories: Sync status history
-- Content Views: Publish status
-- Lifecycle Environments: Promotion status

## Troubleshooting

- No data appearing:
-- Verify cron job is running (/usr/local/bin/SoporeNet_ForemanReportGen-json.sh)
-- Check log files in /var/log/soporenet_foreman_health/
-- Verify database credentials in the script
-- SSH connection issues to capsules
-- Ensure key-based SSH is configured for the Ansible user
-- Verify sudo privileges for the Ansible user on capsules

- Database query failures:
-- Confirm PostgreSQL permissions for the foreman user
-- Check for schema changes if upgrading Foreman


## 🛠️ Customize if Needed

- Update macros or item keys depending on your Foreman setup.
- You can add user parameters or external scripts if your Foreman monitoring depends on custom checks.

## 📄 License

This project is licensed under the [Creative Commons Attribution-NonCommercial 4.0 International License](https://creativecommons.org/licenses/by-nc/4.0/).

You are free to:

- ✅ **Share** — copy and redistribute the material in any medium or format  
- ✅ **Adapt** — remix, transform, and build upon the material  

Under the following terms:

- 📌 **Attribution** — You must give appropriate credit, provide a link to the license, and indicate if changes were made.  
- 🚫 **NonCommercial** — You may not use the material for commercial purposes.

For full legal terms, refer to the license text:  
➡️ https://creativecommons.org/licenses/by-nc/4.0/legalcode
