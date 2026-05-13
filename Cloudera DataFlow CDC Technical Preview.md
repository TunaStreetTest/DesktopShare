---
layout: post
title: "Cloudera DataFlow CDC Technical Preview: Hands-On Review of All ReadyFlows"
date: "2026-05-13"
categories: [cloudera, dataflow, cdc, technical-preview, readyflows, niFi, iceberg, kudu]
tags: [CDC, Debezium, Db2, MySQL, Oracle, PostgreSQL, SQL Server, Iceberg, Kudu, real-time-data]
author: Steven Matison
excerpt: "Deep dive into Cloudera DataFlow’s brand-new CDC ReadyFlows. I walk through every supported source database (Db2, MySQL, Oracle, PostgreSQL, SQL Server) and both Iceberg and Kudu targets — complete with deployment setup, sample database details, and the exact steps you’ll need to get them running in your environment."
image: /assets/images/blog/cdf-cdc-preview-hero.png  <!-- placeholder for hero image -->
reading_time: "25 minute read"
---

# Cloudera DataFlow CDC Technical Preview: Hands-On Review of All ReadyFlows

Hey everyone, Steven Matison here — Cloudera Solutions Engineer and your guide through the world of real-time data orchestration.

Change Data Capture (CDC) has always been one of the most requested capabilities in Cloudera Data Platform, and with the latest **Cloudera DataFlow (CDF) Cloud Technical Preview**, the team has delivered a full suite of **ReadyFlows** that make CDC production-ready out of the box.

In this (very big) post, I’m going to review **every single CDC ReadyFlow** currently available in the Cloudera documentation. For each one I’ll cover:

- What the flow actually does  
- Source and target systems  
- Exact setup and deployment details you’ll need  
- Sample databases I’m using for testing (with DDL and seed data)  
- Configuration gotchas and best practices  

Because this is a **Technical Preview**, things can (and probably will) evolve quickly — I’ll note what’s preview-only and where to watch for changes.

**This post is intentionally structured as a living framework.** I’ll be filling in the full step-by-step instructions, screenshots, configuration snippets, and test results in follow-up deep-dive sessions as I finish building and validating each flow in my lab environments. Think of this as the master blueprint we’ll expand together.

---

## Table of Contents
1. [Why CDC ReadyFlows Matter in Cloudera DataFlow](#why-cdc-readyflows-matter)  
2. [CDC ReadyFlow Overview](#cdc-readyflow-overview)  
3. [Db2 CDC ReadyFlows](#db2-cdc-readyflows)  
4. [MySQL CDC ReadyFlows](#mysql-cdc-readyflows)  
5. [Oracle CDC ReadyFlows](#oracle-cdc-readyflows)  
6. [PostgreSQL CDC ReadyFlows](#postgresql-cdc-readyflows)  
7. [SQL Server CDC ReadyFlows](#sql-server-cdc-readyflows)  
8. [Common Deployment Patterns & Best Practices](#common-deployment-patterns)  
9. [Conclusion & What’s Next](#conclusion)  
10. [You May Also Enjoy](#you-may-also-enjoy)

---

## Why CDC ReadyFlows Matter in Cloudera DataFlow {#why-cdc-readyflows-matter}

Real-time replication from operational databases into modern data platforms is no longer a “nice-to-have.” Enterprises need it for:
- Near-real-time analytics on Iceberg tables
- Operational reporting on Kudu
- Event-driven microservices
- Zero-ETL data pipelines

Cloudera’s new CDC ReadyFlows use battle-tested connectors (mostly Debezium under the hood) and wrap them in production-grade NiFi flows with built-in error handling, schema evolution support, and seamless integration into CDP’s security and governance model.

All of these flows are available today in the **ReadyFlow Catalog** inside Cloudera DataFlow Cloud.

---

## CDC ReadyFlow Overview {#cdc-readyflow-overview}

Cloudera currently ships **ten CDC ReadyFlows**, grouped by source database:

| Source Database | Target: Iceberg (Technical Preview) | Target: Kudu |
|-----------------|-------------------------------------|--------------|
| **Db2**         | ✅ Db2 CDC to Iceberg              | ✅ Db2 CDC to Kudu |
| **MySQL**       | ✅ MySQL CDC to Iceberg            | ✅ MySQL CDC to Kudu |
| **Oracle**      | ✅ Oracle CDC to Iceberg           | ✅ Oracle CDC to Kudu |
| **PostgreSQL**  | ✅ PostgreSQL CDC to Iceberg       | ✅ PostgreSQL CDC to Kudu |
| **SQL Server**  | ✅ SQL Server CDC to Iceberg       | ✅ SQL Server CDC to Kudu |

**Key notes on the preview**:
- All **to-Iceberg** flows are currently marked **Technical Preview**.
- All **to-Kudu** flows are generally available.
- Most flows leverage Debezium for change capture (PostgreSQL and SQL Server explicitly call it out).
- Flows handle row-level INSERT/UPDATE/DELETE events and can be configured for schema evolution.

In the sections below I’ll break each one down with the exact setup details you’ll need to deploy them yourself.

---

## Db2 CDC ReadyFlows {#db2-cdc-readyflows}

### 1. Db2 CDC to Iceberg [Technical Preview]
**Description**: Captures CDC events from a Db2 source table and streams them into an Apache Iceberg destination table.

**Setup Details Needed to Deploy** (to be expanded in deep-dive session):
- [ ] Db2 CDC configuration on source (capture instance, etc.)
- [ ] Connection parameters for the Db2 CDC connector
- [ ] Iceberg catalog configuration in CDF
- [ ] Schema registry and record conversion settings

**Sample Database** (placeholder — I’ll provide full DDL + seed data + CDC enablement scripts here once I build it):
- Database: `SAMPLE`
- Table: `EMPLOYEES`
- CDC setup commands: ...

**Deployment Steps** (placeholder for full instructions):
1. ...
2. ...

### 2. Db2 CDC to Kudu
**Description**: Streams Db2 CDC events directly into a Kudu destination table.

(Full setup, sample DB, and step-by-step deployment coming in the next session.)

---

## MySQL CDC ReadyFlows {#mysql-cdc-readyflows}

### 1. MySQL CDC to Iceberg [Technical Preview]
**Description**: Retrieves CDC events from a MySQL source table and streams them to an Iceberg destination table.

**Setup Details Needed to Deploy**:
- Binary logging must be enabled (`binlog_format=ROW`)
- User privileges for Debezium connector
- Iceberg target table creation

**Sample Database** (placeholder):
- Database: `inventory`
- Table: `products`
- ...

### 2. MySQL CDC to Kudu
**Description**: Streams MySQL CDC events into Kudu.

(Full instructions and sample data coming soon.)

---

## Oracle CDC ReadyFlows {#oracle-cdc-readyflows}

### 1. Oracle CDC to Iceberg [Technical Preview]
**Description**: Captures events from an Oracle table and streams them into Iceberg.

**Setup Details**:
- Oracle LogMiner or XStream configuration
- Supplemental logging
- ...

**Sample Database** (placeholder):
- Schema: `HR`
- Table: `EMPLOYEES`
- ...

### 2. Oracle CDC to Kudu
**Description**: Streams Oracle CDC events to Kudu.

---

## PostgreSQL CDC ReadyFlows {#postgresql-cdc-readyflows}

### 1. PostgreSQL CDC to Iceberg [Technical Preview]
**Description**: Uses Debezium to retrieve events from a PostgreSQL table and stream them into Iceberg.

**Setup Details**:
- `wal_level = logical`
- Publication and replication slot creation
- ...

**Sample Database** (placeholder):
- Database: `pagila`
- Table: `film`
- ...

### 2. PostgreSQL CDC to Kudu
**Description**: Streams PostgreSQL CDC events to Kudu.

---

## SQL Server CDC ReadyFlows {#sql-server-cdc-readyflows}

### 1. SQL Server CDC to Iceberg [Technical Preview]
**Description**: Uses Debezium to retrieve events from a SQL Server table and stream them into Iceberg.

**Setup Details**:
- Enable CDC on the database and table
- ...

**Sample Database** (placeholder):
- Database: `AdventureWorks`
- Table: `Sales.SalesOrderHeader`
- ...

### 2. SQL Server CDC to Kudu
**Description**: Streams SQL Server CDC events to Kudu.

---

## Common Deployment Patterns & Best Practices {#common-deployment-patterns}

- Security & credentials management in CDF
- Schema evolution handling
- Error queues and dead-letter handling
- Scaling the flows
- Monitoring with Cloudera Manager / Prometheus
- Performance tuning tips I discover during testing

(I’ll expand this section heavily once all flows are running in the lab.)

---

## Conclusion & What’s Next {#conclusion}

The new CDC ReadyFlows in Cloudera DataFlow represent a massive leap forward for real-time data movement in the CDP ecosystem. Whether you’re landing changes into Iceberg for lakehouse analytics or Kudu for operational workloads, these pre-built flows remove weeks of custom development.

**Stay tuned** — over the next few weeks I’ll be publishing the full deployment guides, sample databases, configuration files, and test results for each of these ReadyFlows right here on the blog. We’ll turn this framework into the most complete hands-on CDC reference available for Cloudera customers.

If you’re already on CDP Private Cloud or CDF Cloud and want to try these in your environment, drop me a note on X [@StevenMatison](https://x.com/StevenMatison) or LinkedIn — happy to compare notes or help you get the first flow running.

**What’s your biggest CDC use case right now?** Let me know in the comments — I’ll prioritize the deep-dive sessions based on what the community needs most.

---

## You May Also Enjoy
---