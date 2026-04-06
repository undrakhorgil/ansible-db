## Manual runbook (copy/paste on the servers)

Run as **root** unless noted.

The Ansible playbooks target **Oracle Restart on a single host** (exactly one entry in `oracle_hosts`). **Canonical automation** uses **`gridSetup.sh -silent -configureStandaloneServer`** (Ansible **step 7**). Many fenced blocks below still show **two-node RAC**, **SCAN**, or **`CRS_CONFIG`**; treat those as **optional reference** unless you are building RAC by hand.

**`group_vars/all.yml`**, **[`README.md`](README.md)** (steps **1–18**), and **`bash oradbctl.sh -l`** are the source of truth. Use this file when you run commands manually or debug installers.

**Every fenced `bash` block that needs paths or secrets starts with `# --- LAB VARS ---`.** Edit those lines to match your site, then paste the whole block.

Avoid `$`, ```, and `!` in passwords you paste into heredoc blocks; use simple literals or switch to a different quoting style.

### How to use this manual

- **Prefer Ansible** for the normal path: `ansible-playbook playbooks/site.yml` or `bash oradbctl.sh -s <n>` / `-u <n>`.
- Use this manual when you need to **do the same thing by hand**, or when the installer requires interactive troubleshooting.

**Ansible (this repo):** `ansible-playbook playbooks/site.yml` or `bash oradbctl.sh -s …` / `-u …` against `inventory.yml`.
- Steps **1–5** run on the managed host (`oracle_managed_hosts`).
- Steps **6+** run mostly on the primary target (`oracle_hosts[0].host_ip`) for unzip/install.
- `undo 6` empties `GRID_HOME` contents in place.
- `undo 7` re-runs `cleanup_grid_install_state.yml` (locator/inventory pointers), not a full GI deinstall.

For the canonical **oradbctl** order (**1–18**), use **`README.md`** and **`bash oradbctl.sh -l`**.

**Heading mismatch:** Section titles below (e.g. “Step 09”) are **historical** and may not match **oradbctl** numbers. For Restart, prefer the **configureStandaloneServer** flow described in **`README.md`** and the Grid step table.

### Configuration (manual snippets ↔ Ansible)

Every **`# --- LAB VARS ---`** block should match **`group_vars/all.yml`**. Full **required inputs** and explanations: **[`README.md`](README.md)** → **Configure**.

| In `group_vars/all.yml` | Typical manual snippet names |
|---|---|
| **`target_root_password`** | Ansible only; same password if you SSH as root manually |
| **`oracle_hosts[0].host_ip`** | **`PUB_IP`**, SSH target |
| **`oracle_hosts_domain`**, OS short hostname | **`DOMAIN`**, **`SHORT`** in `/etc/hosts` snippets |
| **`oracle_public_subnet`** | Public subnet in legacy RAC **`NET_LIST`** |
| **`oracle_base`**, **`oracle_inventory`**, **`grid_home`**, **`oracle_home`** | **`ORACLE_BASE`**, **`INVENTORY_LOC`**, **`GRID_HOME`**, **`ORACLE_HOME`** |
| **`oracle_grid_software_zip`**, **`oracle_db_software_zip`** | **`GI_ZIP`**, **`DB_ZIP`** (on the **target** host) |
| **`oracle_preinstall_package`** | Same RPM as Ansible step 2 when mirroring packages |
| **`asm_symlinks`**, **`asm_disks`** | Udev **`ID_PATH`**, **`DISK1`/`DISK2`** |
| **`asm_diskgroups`** (**`used_for_grid_crs: true`**) | **`CRS_DG`**, **`DISK_LIST`**, **`REDUNDANCY`**, **`DISK_STRING`** for Restart Grid install |
| **`dbca_data_diskgroup`**, **`dbca_recovery_diskgroup`** | DBCA / ASM names |
| **`sys_password`**, **`dbca_*`** | **`SYS_PW`**, database passwords |

Tunables: **`playbooks/vars/oracle_defaults.yml`**. Secrets: optional **`group_vars/vault.yml`** with **`ansible-playbook --ask-vault-pass`**.

---

### Quick checklist (before Step 06 / GI unzip)

- `/etc/hosts` consistent (Step 01/05)
- `chronyd` running (Step 02)
- `grid`/`oracle` users exist (Step 03)
- `ORACLE_BASE`/`GRID_HOME`/`ORACLE_HOME` exist (Step 04)
- ASM device symlinks exist under `/dev/oracleasm` (Ansible step **5** / `05_shared_disks_udev.yml`)
- Passwordless SSH works for `grid` (manual prep below)

## Step 01 — `/etc/hosts` + SCAN check (all nodes)

```bash
# --- LAB VARS (edit hostnames/IPs to match inventory) ---
# Used only in the heredoc below; change nothing else if defaults are fine.

sudo bash -c "grep -q 'ANSIBLE RAC HOSTS' /etc/hosts || cat >> /etc/hosts <<'EOF'

# BEGIN ANSIBLE RAC HOSTS
# Public lines include FQDN so `hostname -f` resolves (same as rac_domain in group_vars)
192.168.1.101 host01 host01.localdomain
10.0.0.11 host01-priv
192.168.1.111 host01-vip
192.168.1.102 host02 host02.localdomain
10.0.0.12 host02-priv
192.168.1.112 host02-vip
192.168.1.203 scan
192.168.1.204 scan
192.168.1.205 scan
# END ANSIBLE RAC HOSTS
EOF
"

getent hosts scan
hostname -s
```

**VIP and SCAN lines** in `/etc/hosts` are for **name resolution** (cluster/GI expects them). You do **not** need passwordless SSH **to** VIP hostnames—only keep those entries here; SSH checks in **7f** use node names, interconnect `-priv` names, and IPs, not VIPs.

---

## Step 02 — OS packages + chrony (all nodes)

```bash
sudo dnf -y install dnf-utils zip unzip sshpass bc binutils compat-openssl10 elfutils-libelf \
  glibc glibc-devel ksh libaio libXrender libX11 libXau libXi libXtst libgcc libnsl libstdc++ \
  libxcb libibverbs libasan liblsan libubsan make policycoreutils policycoreutils-python-utils \
  smartmontools sysstat libnsl2 libvirt-libs net-tools nfs-utils unixODBC chrony

sudo dnf -y install oracle-ai-database-preinstall-26ai

sudo dnf -y install ipmiutil libnsl2-devel || true

sudo systemctl stop firewalld   2>/dev/null; sudo systemctl disable firewalld 2>/dev/null || true
sudo sed -i 's|SELINUX=enforcing|SELINUX=permissive|' /etc/selinux/config
sudo setenforce 0 2>/dev/null || true
sudo systemctl enable --now chronyd
```

---

## Step 03 — users & groups (all nodes)

```bash
for g in oinstall dba asmadmin asmdba asmoper; do
  getent group "$g" >/dev/null || sudo groupadd "$g"
done

id oracle  &>/dev/null || sudo useradd -m -g oinstall -G dba oracle
sudo usermod -g oinstall -G dba oracle

id grid &>/dev/null || sudo useradd -m -g oinstall -G asmadmin,asmdba,asmoper,dba grid
sudo usermod -g oinstall -G asmadmin,asmdba,asmoper,dba grid
```

---

## Step 04 — empty Oracle paths (all nodes; Ansible)

Ansible step **04** (`04_create_folders.yml`) creates **empty** directories for `ORACLE_BASE`, inventory, `GRID_HOME`, and DB `ORACLE_HOME` on **each** host in `oracle_rac_servers` (same paths everywhere). It does **not** partition disks or mount `/u01`.

Prepare `/u01` (or your chosen filesystem) **before** this step if you need Oracle paths on dedicated storage, e.g.:

```bash
# Example only — adjust devices and fstab for your lab
sudo mkdir -p /u01
# sudo mkfs.xfs /dev/XXX && sudo mount /dev/XXX /u01 && add /etc/fstab entry
```

Then run Ansible step 04 (or `mkdir -p` the same paths as `group_vars`).

---

## Step 05 — refresh `/etc/hosts` (all nodes)

Same block as **Step 01** (re-run the `grep` / `cat >> /etc/hosts` snippet if you changed IPs).

---

## Step 06 — ASM partitions + udev (all nodes)

Prefer **stable** names: partition whole disks under `/dev/disk/by-path/` (no `-part1` on the disk path) and match **`ENV{ID_PATH}`** from each partition so device letters (`sdb`/`sdc`) can change without breaking ASM.

```bash
# --- LAB VARS: set whole-disk by-path targets (ls -l /dev/disk/by-path/) ---
DISK1=/dev/disk/by-path/pci-0000:00:14.0-scsi-0:0:0:0
DISK2=/dev/disk/by-path/pci-0000:00:14.0-scsi-0:0:1:0
# Exact ID_PATH for rules (query the partition; value is often the disk path without "-part1"):
# udevadm info -q property -n "${DISK1}-part1" | grep ^ID_PATH=
# udevadm info -q property -n "${DISK2}-part1" | grep ^ID_PATH=

for d in "$DISK1" "$DISK2"; do
  [ -b "${d}-part1" ] || echo -e "n\np\n1\n\n\nw" | sudo fdisk "$d"
done

sudo mkdir -p /dev/oracleasm
# Without this directory, udev never creates SYMLINK+="oracleasm/..." targets. Persist on reboot:
echo 'd /dev/oracleasm 0755 root root -' | sudo tee /etc/tmpfiles.d/oracle-asmdevices-dev.conf >/dev/null

sudo tee /etc/udev/rules.d/99-oracle-asmdevices.rules >/dev/null <<'EOF'
ENV{ID_PATH}=="pci-0000:00:14.0-scsi-0:0:0:0", ENV{DEVTYPE}=="partition", SUBSYSTEM=="block", SYMLINK+="oracleasm/asm-crs-disk1", OWNER="grid", GROUP="asmadmin", MODE="0660"
ENV{ID_PATH}=="pci-0000:00:14.0-scsi-0:0:1:0", ENV{DEVTYPE}=="partition", SUBSYSTEM=="block", SYMLINK+="oracleasm/asm-crs-disk2", OWNER="grid", GROUP="asmadmin", MODE="0660"
EOF

sudo /sbin/udevadm control --reload-rules
sudo /sbin/udevadm trigger --action=change
sudo /sbin/udevadm settle
ls -l /dev/oracleasm
# Symlinks may show root:root lrwxrwxrwx; confirm permissions on the real block devices:
# ls -l /dev/disk/by-path/*-part1   # expect grid:asmadmin (or your GI user) and mode 660
```

Legacy **`KERNEL=="sdb1"`** rules are still valid if you keep `asm_symlinks` as `{ device: /dev/sdb, name: asm-crs-disk1 }` in Ansible instead of `id_path`.

---

## Step 07 — dirs, passwords, passwordless SSH (all nodes + merge keys)

Keep this step short: it must end with **passwordless SSH working for `grid`** (BatchMode) across all node names/IPs.

If you want the full Ansible-equivalent behavior, read the task file: `roles/oracle_rac/tasks/07_oracle_user_env_ssh.yml`.

```bash
# --- LAB VARS ---
ORACLE_BASE=/u01/app/oracle
INVENTORY_LOC=/u01/app/oraInventory
GRID_HOME=/u01/app/26.0.0/grid
ORACLE_HOME=/u01/app/oracle/product/26.0.0/dbhome_1
LAB_PW='<set-a-lab-password>'

# Create dirs + ownership
sudo mkdir -p "$ORACLE_BASE" "$INVENTORY_LOC" "$GRID_HOME" "$ORACLE_HOME"
sudo chown oracle:oinstall "$ORACLE_BASE" "$ORACLE_HOME"
sudo chown grid:oinstall "$INVENTORY_LOC" "$GRID_HOME"
sudo chmod 775 "$ORACLE_BASE" "$ORACLE_HOME" "$GRID_HOME" "$INVENTORY_LOC"

# Set OS passwords (lab)
echo "oracle:${LAB_PW}" | sudo chpasswd
echo "grid:${LAB_PW}"    | sudo chpasswd

# SSH keys
sudo -u grid   bash -c 'test -f ~/.ssh/id_rsa || ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa'
sudo -u oracle bash -c 'test -f ~/.ssh/id_rsa || ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa'

# Minimal SSH client config (avoid slow checks + enforce pubkey)
for u in oracle grid; do
  sudo install -o "$u" -g oinstall -m 700 -d "/home/$u/.ssh"
  sudo tee "/home/$u/.ssh/config" >/dev/null <<'CFG'
Host *
  StrictHostKeyChecking no
  GSSAPIAuthentication no
  PreferredAuthentications publickey
  PubkeyAuthentication yes
  ConnectTimeout 30
CFG
  sudo chmod 600 "/home/$u/.ssh/config"
  sudo chown "$u":oinstall "/home/$u/.ssh/config"
  sudo install -o "$u" -g oinstall -m 600 /dev/null "/home/$u/.ssh/known_hosts"
done

# Merge grid keys (manual): append both nodes' /home/grid/.ssh/id_rsa.pub into /home/grid/.ssh/authorized_keys on BOTH nodes

# Verify (run on each node)
targets=(host01 host02 host01-priv host02-priv 192.168.1.101 192.168.1.102 10.0.0.11 10.0.0.12 localhost 127.0.0.1)
sudo -u grid -H bash -c 'for t; do
  ssh -o BatchMode=yes -o PasswordAuthentication=no -o PreferredAuthentications=publickey -o ConnectTimeout=15 -o StrictHostKeyChecking=no "grid@$t" true \
    && echo OK "$t" || echo FAIL "$t"
done' bash "${targets[@]}"
```

If you see **FAIL**, fix SSH first (do not continue to CVU / gridSetup).

---

## Step 08 — unzip GI (host01 only, as `grid`)

Ansible step **08** runs the unzip only on `**rac_primary_node`** (default **host01**); it does not push the GI tree to other RAC nodes—copy or rsync `GRID_HOME` yourself if you need the same bits on every node.

```bash
# --- LAB VARS ---
GI_ZIP=/tmp/p38753741_230000_Linux-x86-64.zip
GRID_HOME=/u01/app/26.0.0/grid

unzip -Z1 "$GI_ZIP" | grep -i gridSetup.sh || { echo "Not a GI zip"; exit 1; }

# Optional: wipe GI home contents before re-unzip (matches Ansible undo 8 — keeps empty GRID_HOME)
# sudo find "$GRID_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

sudo -u grid mkdir -p "$GRID_HOME"
sudo unzip -oq "$GI_ZIP" -d "$GRID_HOME"
sudo chown -R grid:oinstall "$GRID_HOME"

find "$GRID_HOME" -maxdepth 20 -type f -name gridSetup.sh -print
```

**8b — Oracle `sshUserSetup.sh` (optional manual only; not in Ansible)**

Use **Step 07** first. If you still want Oracle’s script, run it yourself in a shell (not from the playbook):

```bash
# --- LAB VARS ---
GRID_HOME=/u01/app/26.0.0/grid

SCRIPT=$(find "$GRID_HOME" -type f -name sshUserSetup.sh -print -quit)
[ -n "$SCRIPT" ] || { echo "sshUserSetup.sh not found under $GRID_HOME"; exit 1; }

sudo -u grid -H bash -c "exec timeout 300 bash \"$SCRIPT\" -user grid -hosts \"host01 host02\" -noPromptPassphrase -confirm -advanced" </dev/null
```

---

## Step 10 — `gridSetup.sh` silent (host01 only, as `grid`)

One block: detects `gridSetup.sh`, optional `-responseFile`, then runs install (matches Ansible step file `roles/oracle_rac/tasks/10_gridsetup.yml`). Pass `oracle.install.crs.config.networkInterfaceList` so the installer sees public + private nets (**INS-41102**). For **Oracle Grid 26ai**, the third field is a **numeric** role; word values like `cluster_interconnect` can trigger **INS-08109**. A **two-NIC** cluster should use **Public** + **ASM & Private** on the private NIC (see Oracle GUI doc): in silent form that is typically `**1`** (public) and `**5**` (private / ASM-capable)—`**2**` can yield **INS-41208** (no subnet marked for ASM). Adjust via `rac_grid_network_iface_role_`* or a full `oracle_grid_network_interface_list` override if your build differs.

```bash
# --- LAB VARS ---
ORACLE_BASE=/u01/app/oracle
INVENTORY_LOC=/u01/app/oraInventory
GRID_HOME=/u01/app/26.0.0/grid
SYS_PW='<set-a-lab-password>'
# host01 public + private IPs (same as group_vars rac_nodes for host01)
PUB_IP=192.168.1.101
PRIV_IP=10.0.0.11
PUB_SUB=192.168.1.0
PRIV_SUB=10.0.0.0

# Use addr match, not "ip route get" (local IPs resolve via lo).
PUB_IF=$(ip -o -4 addr show | awk -v ip="$PUB_IP" '$4 ~ "^" ip "/" { print $2; exit }')
PRIV_IF=$(ip -o -4 addr show | awk -v ip="$PRIV_IP" '$4 ~ "^" ip "/" { print $2; exit }')
NET_LIST="${PUB_IF}:${PUB_SUB}:1,${PRIV_IF}:${PRIV_SUB}:5"

GI_SETUP="$GRID_HOME/gridSetup.sh"
[ -x "$GI_SETUP" ] || GI_SETUP=$(find "$GRID_HOME" -maxdepth 20 -type f -name gridSetup.sh -print -quit)
[ -n "$GI_SETUP" ] || { echo "gridSetup.sh not found under $GRID_HOME"; exit 1; }

sudo -u grid -H bash <<EOF
set -euo pipefail
GH=$GRID_HOME
GS=$GI_SETUP
OB=$ORACLE_BASE
IL=$INVENTORY_LOC
SP=$SYS_PW
rsp=()
if [ -f "\$GH/install/response/gridsetup.rsp" ]; then
  rsp=(-responseFile "\$GH/install/response/gridsetup.rsp")
elif [ -f "\$GH/response/gridsetup.rsp" ]; then
  rsp=(-responseFile "\$GH/response/gridsetup.rsp")
fi
bash "\$GS" -ignorePrereq -waitforcompletion -silent "\${rsp[@]}" \\
  INVENTORY_LOCATION="\$IL" \\
  oracle.install.option=CRS_CONFIG \\
  ORACLE_BASE="\$OB" \\
  oracle.install.crs.config.gpnp.scanName=scan \\
  oracle.install.crs.config.gpnp.scanPort=1521 \\
  oracle.install.crs.config.ClusterConfiguration=STANDALONE \\
  oracle.install.crs.config.clusterName=raccluster \\
  oracle.install.crs.config.clusterNodes=host01:host01-vip:HUB,host02:host02-vip:HUB \\
  oracle.install.crs.config.networkInterfaceList=$NET_LIST \\
  oracle.install.asm.OSASM=asmadmin \\
  oracle.install.asm.OSDBA=asmdba \\
  oracle.install.asm.diskGroup.name=CRS \\
  oracle.install.asm.diskGroup.redundancy=EXTERNAL \\
  oracle.install.asm.diskGroup.disks=/dev/oracleasm/asm-crs-disk1,/dev/oracleasm/asm-crs-disk2 \\
  oracle.install.asm.diskGroup.diskDiscoveryString=/dev/oracleasm/* \\
  oracle.install.asm.SYSASMPassword="\$SP" \\
  oracle.install.asm.monitorPassword="\$SP" \\
  oracle.install.crs.rootconfig.executeRootScript=false
EOF
```

Tail logs (host01):

```bash
# --- LAB VARS ---
INVENTORY_LOC=/u01/app/oraInventory

tail -f "$INVENTORY_LOC/logs"/GridSetupActions* 2>/dev/null || true
# or
ls -td /tmp/GridSetupActions* 2>/dev/null | head -1 | xargs -I{} find {} -name 'gridSetupActions*.log' -print -quit | xargs tail -f
```

If the installer prints root scripts, run as **root** on **both** nodes (when prompted):

```bash
# --- LAB VARS ---
INVENTORY_LOC=/u01/app/oraInventory
GRID_HOME=/u01/app/26.0.0/grid

sudo "$INVENTORY_LOC/orainstRoot.sh"
sudo "$GRID_HOME/root.sh"
```

Then, if Oracle instructs you to complete config as `grid` (re-detect installer + optional RSP in one block):

```bash
# --- LAB VARS ---
GRID_HOME=/u01/app/26.0.0/grid

GI_SETUP="$GRID_HOME/gridSetup.sh"
[ -x "$GI_SETUP" ] || GI_SETUP=$(find "$GRID_HOME" -maxdepth 20 -type f -name gridSetup.sh -print -quit)
[ -n "$GI_SETUP" ] || { echo "gridSetup.sh not found"; exit 1; }

sudo -u grid -H bash <<EOF
set -euo pipefail
GH=$GRID_HOME
GS=$GI_SETUP
rsp=()
if [ -f "\$GH/install/response/gridsetup.rsp" ]; then
  rsp=(-responseFile "\$GH/install/response/gridsetup.rsp")
elif [ -f "\$GH/response/gridsetup.rsp" ]; then
  rsp=(-responseFile "\$GH/response/gridsetup.rsp")
fi
bash "\$GS" -silent -executeConfigTools "\${rsp[@]}"
EOF
```

---

## Step 14 — Grid post-check (host01, runtime checks)

```bash
# --- LAB VARS ---
GRID_HOME=/u01/app/26.0.0/grid

"$GRID_HOME/bin/crsctl" stat res -t
"$GRID_HOME/bin/olsnodes" -n
```

---

## Step 15 — DB software unzip + install (host01 only, install uses Step 16)

```bash
# --- LAB VARS ---
DB_ZIP=/tmp/p38743961_230000_Linux-x86-64.zip
ORACLE_HOME=/u01/app/oracle/product/26.0.0/dbhome_1
ORACLE_BASE=/u01/app/oracle
INVENTORY_LOC=/u01/app/oraInventory

unzip -Z1 "$DB_ZIP" | grep -Ei 'runInstaller|rdbms' | head || { echo "Not a DB zip?"; exit 1; }

sudo mkdir -p "$ORACLE_HOME"
sudo chown oracle:oinstall "$ORACLE_HOME"
sudo unzip -oq "$DB_ZIP" -d "$ORACLE_HOME"

sudo -u oracle -H bash <<EOF
set -euo pipefail
OH=$ORACLE_HOME
OB=$ORACLE_BASE
IL=$INVENTORY_LOC
"\$OH/runInstaller" -ignorePrereq -waitforcompletion -silent \\
  -responseFile "\$OH/install/response/db_install.rsp" \\
  installOption=INSTALL_DB_SWONLY \\
  UNIX_GROUP_NAME=oinstall \\
  INVENTORY_LOCATION="\$IL" \\
  ORACLE_HOME="\$OH" \\
  ORACLE_BASE="\$OB" \\
  installEdition=EE \\
  OSDBA=dba OSBACKUPDBA=dba OSDGDBA=dba OSKMDBA=dba OSRACDBA=dba \\
  clusterNodes=host01,host02 \\
  dbType=GENERAL_PURPOSE
EOF
```

---

## Step 17 — DB root scripts (all nodes, as root)

```bash
# --- LAB VARS ---
ORACLE_HOME=/u01/app/oracle/product/26.0.0/dbhome_1

sudo "$ORACLE_HOME/root.sh"
```

---

## Step 18 — DB post-check (host01)

```bash
test -x "$ORACLE_HOME/runInstaller" && echo OK || echo MISSING
```

---

## Step 22 — rotate OS passwords (root + oracle + grid)

```bash
read -rp "New root password: "   R_PW
read -rp "New oracle password: " O_PW
read -rp "New grid password: "   G_PW
echo "root:$R_PW"   | sudo chpasswd
echo "oracle:$O_PW" | sudo chpasswd
echo "grid:$G_PW"   | sudo chpasswd
```

---

## Run everything in order (reference)

On **both** nodes where marked: steps **01–06**, **07a–07c**, **07d** logic on **each** node, **02**, **03**, etc.

Suggested order:

1. 01 → 02 → 03 → 04 → 05 → 06
2. 07 (all substeps on both nodes; complete key merge)
3. 08 → 09 (`runcluvfy`) → 10 (`gridSetup`) → 11 (`root.sh`) → 12 (`executeConfigTools`) on **host01**
4. 13 → 14 on **host01**
5. 15 → 16 on **host01**, then 17 on **both** nodes, then 18 on **host01**
6. 19 (ASM diskgroups) → 20 (create database) → 21 (summary) → 22 (password rotation)

Ansible **step 19** creates ASM diskgroups (`asm_diskgroups` in `group_vars`). **Step 20** creates the database (DBCA). **Step 21** generates `rac_environment_summary.html` on the **control host** (this repo). **Undo** steps are `bash oradbctl.sh -u <n>` (see `README.md`).