
# How To Install Cloudera Iceberg MCP Server

This guide walks you through **Option 2 (Local Install)** of the Cloudera Iceberg MCP Server on a local machine. The Iceberg MCP Server is a Model Context Protocol (MCP) server that gives LLMs and AI agents read-only access to Iceberg tables via Apache Impala. It exposes two powerful tools:  
- `get_schema()` – Lists all tables available in the current database.  
- `execute_query(query: str)` – Runs any SQL query on Impala and returns results as JSON.  

This setup is tested against a **Cloudera Public Cloud (CDP) on AWS** environment and confirmed to work perfectly with **MCP Inspector**.  

The instructions mirror the style and detail of my previous guide: [How To Install Cloudera NiFi MCP Server](https://stevenmatison.com/blog/How-To-Install-Cloudera-NiFi-MCP-Server/).  

---

## Prerequisites

Before you begin, make sure you have the following on your Mac:

1. **Git** – `brew install git` (or already installed via Xcode Command Line Tools).
2. **Node.js** – Required for `npx` and MCP Inspector. Install with:  
   ```bash
   brew install node
   ```
3. **uv** – Modern Python package manager (used by the Iceberg MCP Server). Install with:  
   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```
   Then restart your terminal or run `source $HOME/.cargo/env`.
4. **Cloudera Public Cloud (AWS) access** – You need Impala connection details (see next section).

---

## Step 1: Obtain Impala Connection Details from Cloudera Public Cloud on AWS

The MCP Server connects to your **Impala Virtual Warehouse** (or Data Hub cluster with Impala) in CDP Public Cloud on AWS. Connection is via the Knox gateway (HTTPS, port 443).

### How to get the details:
1. Log in to the **Cloudera Management Console** → **Data Warehouse** service.
2. Select your **Virtual Warehouse** (Impala type).
3. In the **Details** tab or **Connection** section, click **Copy JDBC URL** (or find the Impala coordinator endpoint).
4. The JDBC URL will look similar to this:  
   ```
   jdbc:impala://coordinator-xxx.dw-xxx.a123-4b5c.cloudera.site:443/default;AuthMech=3;transportMode=http;httpPath=cliservice;ssl=1;UID=yourworkloaduser;PWD=yourpassword
   ```
5. Extract these values for the MCP Server environment variables:
   - **IMPALA_HOST** → `coordinator-xxx.dw-xxx.a123-4b5c.cloudera.site` (the hostname only)
   - **IMPALA_PORT** → `443`
   - **IMPALA_USER** → Your workload username (e.g., `srv_cia_test_user` or IAM user)
   - **IMPALA_PASSWORD** → The corresponding password
   - **IMPALA_DATABASE** → Usually `default` (or your target database)

**Tip**: Use a **workload user** or service account with appropriate Impala permissions. Avoid using the admin account for security.

---

## Step 2: Clone the Repository

```bash
# Clone my fork (or your own fork)
git clone https://github.com/cldr-steven-matison/iceberg-mcp-server.git
cd iceberg-mcp-server
```

---

## Step 3: Set Environment Variables

Create a `.env` file in the root of the repository for easy loading (recommended):

```bash
cat > .env << EOF
IMPALA_HOST=coordinator-xxx.dw-xxx.a123-4b5c.cloudera.site
IMPALA_PORT=443
IMPALA_USER=yourworkloaduser
IMPALA_PASSWORD=yourpassword
IMPALA_DATABASE=default
# Optional: Change transport if needed (default is stdio)
# MCP_TRANSPORT=stdio
EOF
```

Load the variables in your current terminal session:

```bash
set -a; source .env; set +a
```

---

## Step 4: Run the MCP Server with MCP Inspector

MCP Inspector is the easiest way to test the server locally.

```bash
# Run MCP Inspector and launch the local server (Option 2)
npx @modelcontextprotocol/inspector \
  uv --directory "$(pwd)" run src/iceberg_mcp_server/server.py
```

This command:
- Opens the MCP Inspector in your browser.
- Launches the Iceberg MCP Server locally using `uv`.

---

## Step 5: Testing – Confirmation Iceberg MCP Services Work with MCP Inspector

Once the inspector loads:

1. **Connect** to the server (it auto-detects the running process).
2. Confirm the server version and status.
3. **List Tools** – You should see:
   - `get_schema()`
   - `execute_query(query: str)`

### Example Tests (copy-paste into Inspector):

**Test 1: Get Schema**
```json
{
  "name": "get_schema",
  "arguments": {}
}
```
→ Returns a JSON list of all tables in the `IMPALA_DATABASE`.

**Test 2: Execute a Simple Query**
```json
{
  "name": "execute_query",
  "arguments": {
    "query": "SHOW TABLES"
  }
}
```
→ Returns table names as JSON.

**Test 3: Real Iceberg Query**
```json
{
  "name": "execute_query",
  "arguments": {
    "query": "SELECT * FROM your_iceberg_table LIMIT 5"
  }
}
```
→ Returns actual data rows.

**Success Confirmation**:  
All tests complete without errors, tools are listed correctly, and queries return valid JSON results from your Cloudera Public Cloud Impala/Iceberg environment. The server is ready for use with Claude Desktop, LangChain, or any MCP client.

---

## Contributing Back – Example PR from Develop Branch

The goal of this exercise is not just installation — it’s to teach **how to contribute** back to the upstream Cloudera project.

### Suggested Contribution (Easy Starter PR)
**Item/Adjustment**: Add official Macintosh local-install instructions + `.env` support + MCP Inspector testing guide to the README.

**Why this is valuable**:
- The current upstream README (`cloudera/iceberg-mcp-server`) only has minimal Option 2 instructions.
- No Mac-specific setup or testing section exists.
- Adding `.env` loading (using `python-dotenv`) would make local dev much smoother for everyone.

### How to Contribute (Step-by-Step)

1. In **your fork** (`cldr-steven-matison/iceberg-mcp-server`):
   ```bash
   git checkout -b develop
   git push -u origin develop
   ```

2. Make the change (example):
   - Update `README.md` with the full Macintosh guide you just followed.
   - (Optional code tweak) Add this to `src/iceberg_mcp_server/server.py` near the top:
     ```python
     from dotenv import load_dotenv
     load_dotenv()  # Loads .env automatically
     ```

3. Commit and push:
   ```bash
   git add README.md src/iceberg_mcp_server/server.py
   git commit -m "feat: add macOS local install guide + .env support + MCP Inspector testing"
   git push
   ```

4. Open a **Pull Request**:
   - Go to your fork on GitHub → Compare & pull request → Base repository: `cloudera/iceberg-mcp-server` → Base branch: `main`
   - Title: "Add macOS Option 2 local install guide, .env support, and MCP Inspector testing"
   - Link back to this blog post for context.

This PR would be merged quickly because it improves documentation and developer experience for the entire community.

---
