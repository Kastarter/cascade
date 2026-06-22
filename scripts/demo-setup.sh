#!/usr/bin/env bash
# Creates the fixture files the Cascade demo (docs/DEMO.md) runs against.
# Everything lands in ~/CascadeDemo so the agent's search/read/write/organize
# use cases have real, predictable material — safe to delete and re-create.
set -euo pipefail

ROOT="$HOME/CascadeDemo"
rm -rf "$ROOT"
mkdir -p "$ROOT/Invoices" "$ROOT/Reports" "$ROOT/Notes" "$ROOT/Inbox"

cat > "$ROOT/Invoices/falcon-invoice-2026-Q2.txt" <<'EOF'
INVOICE  FAL-2026-0614
From: Falcon Logistics Ltd
To:   Humain — Operations

Service: Freight & customs handling, Q2 2026
Amount due: 18,450.00 USD
Issued:  2026-06-01
Due:     2026-06-30
Payment: wire transfer, reference FAL-2026-0614

Contact: accounts@falconlogistics.example
EOF

cat > "$ROOT/Invoices/atlas-invoice-2026-Q1.txt" <<'EOF'
INVOICE  ATL-2026-0118
From: Atlas Cloud Services
To:   Humain — Engineering

Service: Compute reservation, Q1 2026
Amount due: 7,200.00 USD
Issued:  2026-01-15
Due:     2026-02-15  (PAID 2026-02-11)
EOF

# Two more OPEN invoices in the SAME field layout as Falcon, so logging each one
# is the identical copy→paste rhythm — the "boring AP entry" loop Demo 2 teaches.
cat > "$ROOT/Invoices/meridian-invoice-2026-0608.txt" <<'EOF'
INVOICE  MER-2026-0608
From: Meridian Office Supplies
To:   Humain — Operations

Service: Office furniture & supplies, Q2 2026
Amount due: 4,820.00 USD
Issued:  2026-06-05
Due:     2026-07-05
Payment: wire transfer, reference MER-2026-0608

Contact: billing@meridian.example
EOF

cat > "$ROOT/Invoices/vertex-invoice-2026-0611.txt" <<'EOF'
INVOICE  VTX-2026-0611
From: Vertex Consulting
To:   Humain — Strategy

Service: Advisory retainer, June 2026
Amount due: 9,600.00 USD
Issued:  2026-06-10
Due:     2026-07-10
Payment: wire transfer, reference VTX-2026-0611

Contact: ar@vertex.example
EOF

# The AP tracker the invoices get logged into (open it in Numbers). One row is
# already filled so it reads as an ongoing ledger — you add the next rows by hand.
cat > "$ROOT/Invoices/invoice-tracker.csv" <<'EOF'
Vendor,Invoice #,Amount USD,Due date,Status
Orbit Media,ORB-2026-0512,3300.00,2026-05-30,Logged
EOF

cat > "$ROOT/Reports/quarterly-report-Q1-2026.csv" <<'EOF'
month,revenue_usd,new_customers,churned
January,128400,23,4
February,131900,19,6
March,142750,31,3
EOF

cat > "$ROOT/Reports/quarterly-report-Q2-2026.csv" <<'EOF'
month,revenue_usd,new_customers,churned
April,149200,27,5
May,156800,35,2
June,163100,38,4
EOF

cat > "$ROOT/Notes/meeting-notes-roadmap.md" <<'EOF'
# Roadmap sync — 2026-06-08

Attendees: K, S, M

Decisions:
- Ship the agent harness behind a settings toggle (done)
- Demo recording scheduled for mid-June

Action items:
- [ ] K: pay the Falcon logistics invoice before end of month
- [ ] S: prepare Q2 numbers comparison for the all-hands
- [ ] M: draft the customer-update email about the new dashboard
EOF

cat > "$ROOT/team-contacts.csv" <<'EOF'
name,role,email
Sara Khan,Finance lead,sara@humain.example
Marco Diaz,Customer success,marco@humain.example
Lena Fischer,Engineering,lena@humain.example
EOF

# A messy inbox for the "organize this" use case — mixed types, no structure.
echo "Scanned receipt — taxi to airport, 64.50 SAR, 2026-06-02"            > "$ROOT/Inbox/receipt-taxi-jun02.txt"
echo "Scanned receipt — team dinner, 412.00 SAR, 2026-06-05"               > "$ROOT/Inbox/receipt-dinner-jun05.txt"
echo "Draft: customer update — new dashboard ships next week."             > "$ROOT/Inbox/draft-customer-update.md"
echo "Draft: blog post outline — why local context beats cloud capture."   > "$ROOT/Inbox/draft-blog-outline.md"
echo "TODO: renew the office lease paperwork before July."                 > "$ROOT/Inbox/todo-lease.txt"
echo "month,signups\nJanuary,210\nFebruary,198"                            > "$ROOT/Inbox/old-signups-data.csv"

echo "Demo fixtures ready at $ROOT"
echo "Manual props still needed: one email in Mail you can reply to,"
echo "and Settings → Agent harness → Power harness ON."
echo "Demo 2 (Teach once): open Invoices/invoice-tracker.csv in Numbers,"
echo "and have an invoice .txt open beside it (Falcon / Meridian / Vertex)."
