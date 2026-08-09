# CommCenter Pro v0.3.0 — EMS Operations

This release adds a dedicated EMS patient-flow layer while keeping CommCenter Pro separate from the clinical ePCR.

## New operational resource types

- EMS Field Team
- Ambulance / transport-capable EMS unit
- EMS Command
- Treatment Area

Existing CAD units remain in `units`; EMS behavior is added with `ems_unit_config`.

## Treatment Area Station interface

From the CommCenter Pro landing page choose **Treatment Area Station**.

The station uses:

1. Event ID
2. Event 4-digit field PIN
3. Treatment-area selection

The treatment-area dashboard includes:

- current occupancy / capacity
- OPEN / LIMITED / FULL / CLOSED status
- accepting-patients toggle
- incoming handoff queue
- Accept / Decline handoff
- patients currently in treatment
- walk-in patient tracking creation
- request ambulance handoff
- cancel pending ambulance request
- release/close patient tracking
- realtime refresh when EMS encounters/handoffs change

## Patient tracking

CommCenter Pro creates event-scoped operational IDs:

`PT-0001`, `PT-0002`, etc.

The tracking record stores operational custody/flow information only. It is not intended to replace an ePCR.

## Handoff workflow

Supported normal paths:

- Field Team -> Treatment Area
- Field Team -> Ambulance
- Treatment Area -> Ambulance

A handoff is not complete when the sender requests it. The receiving resource must **Accept** the handoff. Until then, custody remains with the sending resource.

## EMS Command interface

Named dispatch/admin users get an **EMS Ops** button from Unified Dispatch with:

- active patient count
- patient count with field teams
- patient count in treatment
- patient count with ambulances
- pending handoff count
- treatment-area capacity cards
- ambulance status cards
- active patient tracking table
- pending and recent handoff views

## Event Admin -> EMS Setup

Configure:

- treatment areas
- capacity
- POI/common-name link
- department link
- existing CAD units as Field Team / Ambulance / EMS Command
- transport-capable status
- BLS / ALS / CCT / Other ambulance level
