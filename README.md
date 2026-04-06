## Oracle Grid 26ai Ansible (Oracle Restart only)

**Repository:** [https://github.com/undrakhorgil/ansible-db](https://github.com/undrakhorgil/ansible-db)

Step-based automation for **Oracle Restart** on **one server**: OS prep → unzip Grid image → `gridSetup.sh` standalone server (Oracle Restart + ASM) → root scripts → execute config tools → DB software → **single-instance** DBCA on ASM. There is **no** RAC, SCAN, or multi-node cluster path in this repo.

### Quickstart

```bash
ansible-galaxy collection install -r collections/requirements.yml
${EDITOR:-vi} group_vars/all.yml
# Optional: ansible-vault encrypt group_vars/vault.yml and pass --ask-vault-pass when running playbooks.
ansible-playbook playbooks/site.yml
```

Use **`bash oradbctl.sh -l`** to list steps and **`bash oradbctl.sh -s -r 1-18`** for a full ordered run with local step status in `.oradbctl.state`.

### Project structure

```text
ansible-db/
  oradbctl.sh                   # Step/undo runner (18 numbered steps)
  group_vars/all.yml            # Single host: oracle_hosts + paths + ASM + DBCA
  playbooks/site.yml            # Full run
  playbooks/bootstrap_inventory.yml   # Builds oracle_managed_hosts (exactly one host) from group_vars
  scripts/create_database_dbca.sh       # Optional manual DBCA helper (same ASM / srvctl prechecks as step 16)
  playbooks/tasks/oracle/       # 00_topology… + 01–18 + undo_* + helpers
  playbooks/templates/          # Jinja for PAM limits, topology JSON, HTML summary
  playbooks/vars/oracle_defaults.yml  # low-precedence defaults (topology helpers, Grid NIC options)
  grid_environment_summary.html     # Generated on control host (step 17 / `17_summary.yml`)
```

### Configure

Edit **`group_vars/all.yml`** (and optionally **`group_vars/vault.yml`** for secrets). **`playbooks/site.yml`** loads **`playbooks/vars/oracle_defaults.yml`** after group vars, so defaults you do not set come from there; see that file for tunables (Grid async timeouts, `oracle_database_compatible_rdbms`, undo flags, second NIC roles, etc.).

#### Required inputs (what you must set correctly)

| Variable / block | Purpose |
|---|---|
| **`target_root_password`** | SSH password Ansible uses as **`root`** on the target (`ansible_password` in `site.yml`). Use vault or `ansible-playbook --ask-vault-pass` if you encrypt secrets. |
| **`oracle_hosts`** | **Exactly one** list element with **`host_ip`**: the address Ansible uses as the inventory host name (SSH target). Oracle Grid and `/etc/hosts` logic still use the machine’s real short hostname (**`ansible_hostname`**), e.g. `host03` — you do not repeat that in `oracle_hosts` unless you add optional keys below. |
| **`oracle_public_subnet`** | Network address of the public subnet (e.g. `192.168.1.0`), **not** CIDR. Must match the interface netmask on the server; fed into Grid networking during install. |
| **`oracle_hosts_domain`** | Domain suffix for FQDN in `/etc/hosts` (e.g. `localdomain`). Should match **`hostname -f`** on the target. |
| **`oracle_base`**, **`oracle_inventory`**, **`grid_home`**, **`oracle_home`** | Filesystem layout: shared Oracle base, OUI inventory location, Grid home, database home. Paths must exist or be creatable; zips unpack into **`grid_home`** and **`oracle_home`**. |
| **`oracle_user`**, **`grid_user`**, **`oinstall_group`**, **`dba_group`**, **`asmadmin_group`**, **`asmdba_group`**, **`asmoper_group`** | OS names the playbooks use for ownership and group membership (typically `oracle`, `grid`, `oinstall`, `dba`, `asmadmin`, `asmdba`, `asmoper`). |
| **`oracle_grid_software_zip`**, **`oracle_db_software_zip`** | **Paths on the target** (not on the control node) to the GI and DB media zip files. |
| **`oracle_preinstall_package`** | RPM name for Oracle’s preinstall package (e.g. `oracle-ai-database-preinstall-26ai` on RHEL-compatible systems). |
| **`asm_disks`** | List of **whole-disk** `/dev/disk/by-path/...` devices (no `-part1`); step 5 partitions them if needed. |
| **`asm_symlinks`** | Udev: each item maps **`id_path`** (same style as `udevadm info` on the partition) to a name under **`/dev/oracleasm/`** (e.g. `asm-crs-disk1`). Must line up with the disks you partitioned. |
| **`asm_diskgroups`** | ASM disk group definitions: **`name`**, **`redundancy`**, **`disks`** (paths under `/dev/oracleasm/...`). **Exactly one** entry must have **`used_for_grid_crs: true`** — that group is created during **Grid setup** (CRS/OCR/VOTE). Other groups are created in **step 15** (e.g. **FRA**). Names here must match **`dbca_data_diskgroup`** / **`dbca_recovery_diskgroup`** if those are the same disks. |
| **`grid_asm_disk_discovery_string`** | Discovery string for Grid/ASM (e.g. `"/dev/oracleasm/*"`). |
| **`sys_password`** | ASM **SYSASM**-related passwords for Grid silent install (and related installer prompts). |
| **`root_user_password_*`**, **`oracle_user_password_*`**, **`grid_user_password_*`** | Old/new passwords for **step 18** (rotation). Set **`_old`** to the current OS passwords and **`_new`** to the desired values. |
| **`dbca_*`** | Database creation: SID, global DB name, PDB name, character set, **database** passwords, **`dbca_data_diskgroup`** / **`dbca_recovery_diskgroup`** (must match ASM group names), FRA size, timeouts, **`dbca_drop_existing_before_create`**, and checks like **`dbca_enforce_oracle_home_path_matches_oraversion`** / **`dbca_skip_db_home_inventory_mismatch_check`** when your **DB zip version** and **ORACLE_HOME path** do not match (see Troubleshooting). |

#### Optional host entry keys (unusual for Restart)

| Variable | When to set |
|---|---|
| **`private_ip`** on the **`oracle_hosts[0]`** object | Second NIC / private interconnect when **`oracle_use_private_network: true`** in **`group_vars`** (see **`oracle_defaults.yml`** for **`oracle_private_subnet`**, **`oracle_grid_network_interface_list`**, role IDs). |

#### Inventory bootstrap

**`playbooks/bootstrap_inventory.yml`** builds the **`oracle_managed_hosts`** group from **`oracle_hosts`** so **`inventory.yml`** can stay minimal. No manual inventory editing is required for the single-host case beyond **`group_vars/all.yml`**.

#### Operational defaults already in `all.yml` (adjust per lab)

- **`ansible_remote_tmp`**: writable temp for modules (avoids `~/.ansible` permission issues for `oracle`/`grid`).
- **`asm_wipe_stale_headers`**, **`asm_wipe_header_mb`**: clearing old ASM headers before Grid install (see comments in **`all.yml`** / **`oracle_defaults.yml`**).
- **`oracle_show_cmd_output`**, Grid/DBCA booleans: verbosity and installer behavior; read inline comments in **`group_vars/all.yml`** before changing.

### Run (step / undo)

```bash
bash oradbctl.sh -l
bash oradbctl.sh -s 1
bash oradbctl.sh -s -r 1-18
bash oradbctl.sh -u 7
```

### Step map (18 steps)

`/etc/hosts` is written in **step 01** (precheck).

| Step | Name | Runs on | Notes |
|---:|---|---|---|
| 01 | Precheck networking | managed host | `/etc/hosts` block, name resolution |
| 02 | OS packages & time sync | managed host | |
| 03 | Users, groups, limits | managed host | |
| 04 | Create Oracle directories | managed host | |
| 05 | Shared disks (ASM) + udev | managed host | |
| 06 | Unzip Grid Infrastructure | primary | unzip image zip into `grid_home` |
| 07 | Grid setup | primary | `gridSetup.sh -silent -configureStandaloneServer` |
| 08 | Run GI root scripts | managed host | `grid_home/root.sh` |
| 09 | Execute GI config tools | primary | `gridSetup.sh -executeConfigTools` |
| 10 | GI postcheck | primary | `crsctl`/`srvctl` basic checks |
| 11 | Unzip DB software | primary | |
| 12 | Install DB software | primary | |
| 13 | Run DB root scripts | managed host | `oracle_home/root.sh` |
| 14 | DB postcheck | primary | |
| 15 | Create ASM disk groups | managed host | Non-CRS DGs; mount |
| 16 | Create database (DBCA) | primary | Single-instance on ASM; mounts DGs, `srvctl start diskgroup`, MOUNTED check, Grid lib on `LD_LIBRARY_PATH`, `srvctl modify database` for DG deps |
| 17 | Summary | control host | `grid_environment_summary.html` |
| 18 | Rotate passwords | managed host | root / oracle / grid |

Task files use numeric prefixes **`01_`–`18_`** aligned with **oradbctl** steps **1–18** (e.g. step 11 → `11_db_software_unzip.yml`, step 18 → `18_change_all_passwords.yml`).

### Notes

- With **`group_vars/all.yml`** matching your host, software zips, and ASM layout, a full **`ansible-playbook playbooks/site.yml`** or **`bash oradbctl.sh -s -r 1-18`** is the supported end-to-end path (Oracle Restart + single-instance DBCA on ASM).
- Undo for GI configuration steps is intentionally limited; use Oracle deinstall/deconfig procedures if rollback is required.

### Troubleshooting

- **`/dev/oracleasm/asm-*` missing**: check udev / `ID_PATH` (step 5).
- **DBCA ORA-15001** (“diskgroup not mounted” during RMAN restore): **Step 16** runs `mount_asm_diskgroups`, asserts both DBCA disk groups are **MOUNTED** in `v$asm_diskgroup`, then immediately before `dbca` runs **`srvctl start diskgroup`** for the data and FRA groups and re-checks the MOUNTED count as **grid** via `sqlplus / as sysasm`. Ensure **`LD_LIBRARY_PATH`** includes **`grid_home/lib`** (the playbook exports this for DBCA). After success, the play registers the DB with **`srvctl modify database -diskgroup`** so CRS starts disk groups before the database.
- **DBCA / `OracleHome.getVersion` vs path**: DBCA uses the same home catalog as **`oraversion`**. If the DB home path says 26.x but **`oraversion -majorVersion`** shows 23.x (or `inventory.xml` disagrees), fix OUI registration (detach/attach or reinstall) or align paths and zips — step 16 can fail fast on this mismatch unless you deliberately relax checks in `group_vars`.
- **Manual DBCA**: see **`scripts/create_database_dbca.sh`** for a shell flow that mirrors the pre-DBCA ASM checks.
