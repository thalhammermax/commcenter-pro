import { supabase } from "./supabase.js";

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({
  "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"
}[m]));

const TERMINAL_STATUSES=new Set(["COMPLETE","NO_SHOW","CANCELLED"]);

let logisticsChannel=null;

function dateTime24(value){
  if(!value)return "—";
  const d=new Date(value);
  if(Number.isNaN(d.getTime()))return "—";
  return d.toLocaleString([],{
    year:"numeric",
    month:"2-digit",
    day:"2-digit",
    hour:"2-digit",
    minute:"2-digit",
    hour12:false,
    hourCycle:"h23"
  });
}

function time24(value){
  if(!value)return "—";
  const d=new Date(value);
  if(Number.isNaN(d.getTime()))return "—";
  return d.toLocaleTimeString([],{
    hour:"2-digit",
    minute:"2-digit",
    hour12:false,
    hourCycle:"h23"
  });
}

function dateInputValue(value){
  if(!value)return "";
  const d=new Date(value);
  if(Number.isNaN(d.getTime()))return "";
  const pad=n=>String(n).padStart(2,"0");
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function parseLocalDateTime24(raw){
  const value=String(raw||"").trim();
  if(!value)return null;

  // Preferred / documented import format.
  let match=value.match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/);
  if(match){
    const [,year,month,day,hour,minute]=match;
    const d=new Date(
      Number(year),
      Number(month)-1,
      Number(day),
      Number(hour),
      Number(minute),
      0,
      0
    );
    if(
      d.getFullYear()!==Number(year)
      ||d.getMonth()!==Number(month)-1
      ||d.getDate()!==Number(day)
      ||d.getHours()!==Number(hour)
      ||d.getMinutes()!==Number(minute)
    )return null;
    return d.toISOString();
  }

  // ISO timestamps exported by another system are also accepted.
  if(/^\d{4}-\d{2}-\d{2}T/.test(value)){
    const d=new Date(value);
    if(!Number.isNaN(d.getTime()))return d.toISOString();
  }

  return null;
}

function movementTypeLabel(type){
  return ({
    AIRPORT_ARRIVAL:"Airport Arrival",
    AIRPORT_DEPARTURE:"Airport Departure",
    HOTEL_TRANSFER:"Hotel Transfer",
    VENUE_TRANSFER:"Venue Transfer",
    LOCAL_TRANSFER:"Local Transfer",
    OTHER:"Other Movement"
  })[type]||String(type||"Movement").replaceAll("_"," ");
}

function movementStatusLabel(status){
  return ({
    SCHEDULED:"Scheduled",
    READY:"Ready",
    ASSIGNED:"Driver Assigned",
    EN_ROUTE_PICKUP:"En Route to Pickup",
    AT_PICKUP:"At Pickup",
    PASSENGER_ONBOARD:"Guest On Board",
    EN_ROUTE_DESTINATION:"En Route to Destination",
    COMPLETE:"Complete",
    NO_SHOW:"No Show",
    CANCELLED:"Cancelled"
  })[status]||String(status||"").replaceAll("_"," ");
}

function movementStatusClass(status){
  return `logistics-status-${String(status||"").toLowerCase().replaceAll("_","-")}`;
}

function movementTypeOptions(selected="OTHER"){
  return [
    ["AIRPORT_ARRIVAL","Airport Arrival"],
    ["AIRPORT_DEPARTURE","Airport Departure"],
    ["HOTEL_TRANSFER","Hotel Transfer"],
    ["VENUE_TRANSFER","Venue Transfer"],
    ["LOCAL_TRANSFER","Local Transfer"],
    ["OTHER","Other Movement"]
  ].map(([value,label])=>`<option value="${value}" ${value===selected?"selected":""}>${label}</option>`).join("");
}

function csvEscape(value){
  return `"${String(value??"").replaceAll('"','""')}"`;
}

function downloadCsv(filename,columns,rows){
  const body=[
    columns.map(c=>csvEscape(c.label)).join(","),
    ...rows.map(row=>columns.map(c=>csvEscape(
      typeof c.value==="function"?c.value(row):row[c.value]
    )).join(","))
  ].join("\n");

  const href=URL.createObjectURL(new Blob([body],{type:"text/csv;charset=utf-8"}));
  const link=document.createElement("a");
  link.href=href;
  link.download=filename;
  link.click();
  setTimeout(()=>URL.revokeObjectURL(href),0);
}

function parseCsv(text){
  const rows=[];
  let row=[];
  let field="";
  let quoted=false;

  for(let i=0;i<text.length;i++){
    const ch=text[i];
    const next=text[i+1];

    if(quoted){
      if(ch==='"'&&next==='"'){
        field+='"';
        i++;
      }else if(ch==='"'){
        quoted=false;
      }else{
        field+=ch;
      }
      continue;
    }

    if(ch==='"'){
      quoted=true;
    }else if(ch===","){
      row.push(field);
      field="";
    }else if(ch==="\n"){
      row.push(field.replace(/\r$/,""));
      rows.push(row);
      row=[];
      field="";
    }else{
      field+=ch;
    }
  }

  row.push(field.replace(/\r$/,""));
  if(row.some(cell=>cell!==""))rows.push(row);
  return rows;
}

function normalizeHeader(value){
  return String(value||"")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g,"_")
    .replace(/^_|_$/g,"");
}

function mapCsvRows(text,ctx){
  const matrix=parseCsv(text);
  if(matrix.length<2)return {rows:[],errors:["CSV does not contain any data rows."]};

  const headers=matrix[0].map(normalizeHeader);
  const aliases={
    guest:"guest_name",
    name:"guest_name",
    passenger:"guest_name",
    passenger_name:"guest_name",
    guest_party:"guest_name",
    group:"guest_group",
    organization:"guest_group",
    party:"guest_group",
    count:"party_size",
    passengers:"party_size",
    pax:"party_size",
    scheduled:"scheduled_time",
    scheduled_at:"scheduled_time",
    pickup_time:"scheduled_time",
    time:"scheduled_time",
    type:"movement_type",
    pickup:"origin",
    pickup_location:"origin",
    from:"origin",
    dropoff:"destination",
    drop_off:"destination",
    dropoff_location:"destination",
    to:"destination",
    phone:"contact_phone",
    mobile:"contact_phone",
    email:"contact_email",
    flight:"flight_number",
    flight_no:"flight_number",
    flight_number:"flight_number",
    carrier:"airline",
    airport_code:"airport",
    confirmation:"external_reference",
    reference:"external_reference",
    ref:"external_reference",
    operational_period:"operational_period"
  };

  const canonical=headers.map(h=>aliases[h]||h);
  const required=["guest_name","scheduled_time","origin","destination"];
  const missing=required.filter(field=>!canonical.includes(field));
  if(missing.length){
    return {
      rows:[],
      errors:[`Missing required column(s): ${missing.join(", ")}`]
    };
  }

  const periodByName=new Map(
    (ctx.operationalPeriods||[]).flatMap(op=>[
      [String(op.name||"").trim().toLowerCase(),op.id],
      [String(op.incident_prefix||"").trim().toLowerCase(),op.id]
    ])
  );

  const rows=[];
  const errors=[];

  matrix.slice(1).forEach((values,index)=>{
    if(values.every(v=>!String(v||"").trim()))return;

    const raw={};
    canonical.forEach((key,column)=>{
      raw[key]=String(values[column]??"").trim();
    });

    const line=index+2;
    const scheduledAt=parseLocalDateTime24(raw.scheduled_time);
    const partySize=raw.party_size?Number.parseInt(raw.party_size,10):1;
    const movementType=String(raw.movement_type||"OTHER").trim().toUpperCase().replace(/\s+/g,"_");
    const opKey=String(raw.operational_period||"").trim().toLowerCase();

    if(!raw.guest_name)errors.push(`Row ${line}: guest_name is required.`);
    if(!scheduledAt)errors.push(`Row ${line}: scheduled_time must be YYYY-MM-DD HH:mm or an ISO timestamp.`);
    if(!raw.origin)errors.push(`Row ${line}: origin is required.`);
    if(!raw.destination)errors.push(`Row ${line}: destination is required.`);
    if(!Number.isFinite(partySize)||partySize<1)errors.push(`Row ${line}: party_size must be at least 1.`);
    if(!["AIRPORT_ARRIVAL","AIRPORT_DEPARTURE","HOTEL_TRANSFER","VENUE_TRANSFER","LOCAL_TRANSFER","OTHER"].includes(movementType)){
      errors.push(`Row ${line}: movement_type is not recognized.`);
    }

    rows.push({
      guest_name:raw.guest_name,
      guest_group:raw.guest_group||null,
      party_size:Number.isFinite(partySize)&&partySize>=1?partySize:1,
      scheduled_at:scheduledAt,
      movement_type:movementType,
      origin:raw.origin,
      destination:raw.destination,
      airline:raw.airline||null,
      flight_number:raw.flight_number||null,
      airport:raw.airport||null,
      terminal:raw.terminal||null,
      contact_phone:raw.contact_phone||null,
      contact_email:raw.contact_email||null,
      external_reference:raw.external_reference||null,
      operational_period_id:opKey?(periodByName.get(opKey)||null):null,
      notes:raw.notes||null
    });
  });

  return {rows,errors};
}

function logisticsDepartments(ctx){
  const all=(ctx.departments||[]).filter(d=>d.active!==false&&d.guest_logistics_enabled===true);
  if(Array.isArray(ctx.dispatchDepartmentIds)&&ctx.dispatchDepartmentIds.length){
    const selected=new Set(ctx.dispatchDepartmentIds);
    return all.filter(dep=>selected.has(dep.id));
  }
  return all;
}

function activeCadAssignment(unitId,ctx){
  for(const incident of ctx.incidents||[]){
    const link=(incident.incident_units||[]).find(item=>item.unit_id===unitId&&!item.cleared_at);
    if(link)return incident;
  }
  return null;
}

function activeMovementForUnit(unitId,movements,currentId=null){
  return (movements||[]).find(m=>
    m.assigned_unit_id===unitId
    &&m.id!==currentId
    &&["EN_ROUTE_PICKUP","AT_PICKUP","PASSENGER_ONBOARD","EN_ROUTE_DESTINATION"].includes(m.status)
  )||null;
}

function driverUnitOptions(ctx,movements,movement){
  const logisticsDeptIds=new Set(logisticsDepartments(ctx).map(d=>d.id));
  return (ctx.units||[])
    .filter(unit=>unit.active!==false&&logisticsDeptIds.has(unit.department_id))
    .map(unit=>{
      const cad=activeCadAssignment(unit.id,ctx);
      const other=activeMovementForUnit(unit.id,movements,movement.id);
      const suffix=other
        ?` · UNDERWAY ${other.movement_number}`
        :cad
          ?` · CAD ${cad.incident_number}`
          :` · ${String(unit.status||"").replaceAll("_"," ")}`;
      return `<option value="${unit.id}" ${unit.id===movement.assigned_unit_id?"selected":""}>${esc(unit.name)}${esc(suffix)}</option>`;
    })
    .join("");
}

function ensureModal(){
  let modal=document.querySelector("#guestLogisticsModal");
  if(modal)return modal;

  document.body.insertAdjacentHTML("beforeend",`
    <div class="logistics-modal-backdrop" id="guestLogisticsModal" aria-hidden="true">
      <div class="logistics-modal" role="dialog" aria-modal="true">
        <div id="guestLogisticsModalContent"></div>
      </div>
    </div>
  `);

  modal=document.querySelector("#guestLogisticsModal");
  modal.addEventListener("mousedown",event=>{
    if(event.target===modal)closeModal();
  });

  return modal;
}

function openModal(){
  const modal=ensureModal();
  modal.classList.add("open");
  modal.setAttribute("aria-hidden","false");
  document.body.classList.add("modal-open");
  return document.querySelector("#guestLogisticsModalContent");
}

function closeModal(){
  const modal=document.querySelector("#guestLogisticsModal");
  if(modal){
    modal.classList.remove("open");
    modal.setAttribute("aria-hidden","true");
  }
  document.body.classList.remove("modal-open");
}

async function fetchMovements(eventId){
  const {data,error}=await supabase.from("guest_logistics_movements")
    .select("*")
    .eq("event_id",eventId)
    .order("scheduled_at");

  if(error)throw error;
  return data||[];
}

async function fetchActivity(movementId){
  const {data,error}=await supabase.from("guest_logistics_activity")
    .select("*")
    .eq("movement_id",movementId)
    .order("created_at");

  if(error)throw error;
  return data||[];
}

function nextStatusActions(movement){
  switch(movement.status){
    case "SCHEDULED":
      return [["READY","Mark Ready","secondary"],["CANCELLED","Cancel","danger"]];
    case "READY":
      return [["CANCELLED","Cancel","danger"]];
    case "ASSIGNED":
      return [["EN_ROUTE_PICKUP","En Route to Pickup","good"],["CANCELLED","Cancel","danger"]];
    case "EN_ROUTE_PICKUP":
      return [["AT_PICKUP","Arrived at Pickup","good"],["CANCELLED","Cancel","danger"]];
    case "AT_PICKUP":
      return [
        ["PASSENGER_ONBOARD","Guest On Board","good"],
        ["NO_SHOW","No Show","danger"],
        ["CANCELLED","Cancel","danger"]
      ];
    case "PASSENGER_ONBOARD":
      return [["EN_ROUTE_DESTINATION","En Route to Destination","good"]];
    case "EN_ROUTE_DESTINATION":
      return [["COMPLETE","Arrived / Complete","good"]];
    default:
      return [];
  }
}

function movementCard(movement,ctx){
  const unit=(ctx.units||[]).find(u=>u.id===movement.assigned_unit_id);
  const department=(ctx.departments||[]).find(d=>d.id===movement.department_id);
  const flight=[movement.airline,movement.flight_number].filter(Boolean).join(" ");
  const overdue=!TERMINAL_STATUSES.has(movement.status)&&new Date(movement.scheduled_at).getTime()<Date.now()-15*60*1000;

  return `<article class="logistics-movement-card ${overdue?"logistics-overdue":""}" data-movement-card="${movement.id}">
    <div class="logistics-movement-time">
      <strong>${esc(time24(movement.scheduled_at))}</strong>
      <span>${esc(new Date(movement.scheduled_at).toLocaleDateString([],{month:"2-digit",day:"2-digit"}))}</span>
    </div>

    <div class="logistics-movement-main">
      <div class="row start">
        <strong>${esc(movement.movement_number)}</strong>
        <span class="badge ${movementStatusClass(movement.status)}">${esc(movementStatusLabel(movement.status))}</span>
        ${movement.driver_acknowledged_at?`<span class="badge logistics-ack-badge">ACK</span>`:""}
        ${overdue?`<span class="badge logistics-overdue-badge">PAST DUE</span>`:""}
      </div>
      <div class="logistics-guest-line">${esc(movement.guest_name)}${movement.guest_group?` · ${esc(movement.guest_group)}`:""} · ${movement.party_size} pax</div>
      <div class="small muted">${esc(movementTypeLabel(movement.movement_type))}${flight?` · ${esc(flight)}`:""}${movement.airport?` · ${esc(movement.airport)}`:""}</div>
      <div class="logistics-route"><span>${esc(movement.origin)}</span><strong>→</strong><span>${esc(movement.destination)}</span></div>
      <div class="small">${department?`${esc(department.short_name||department.name)} · `:""}Driver: <strong>${esc(unit?.name||"Unassigned")}</strong></div>
    </div>

    <button class="btn secondary compact" data-logistics-open="${movement.id}">Details / Dispatch</button>
  </article>`;
}

function movementSearchText(movement,ctx){
  const unit=(ctx.units||[]).find(u=>u.id===movement.assigned_unit_id);
  return [
    movement.movement_number,
    movement.guest_name,
    movement.guest_group,
    movement.origin,
    movement.destination,
    movement.flight_number,
    movement.airline,
    movement.airport,
    movement.terminal,
    movement.external_reference,
    movement.notes,
    unit?.name,
    movement.status,
    movement.movement_type
  ].filter(Boolean).join(" ").toLowerCase();
}

function movementFormHtml(ctx,movement=null,defaultDepartmentId=null){
  const departments=logisticsDepartments(ctx);
  const opOptions=(ctx.operationalPeriods||[]).filter(op=>op.status!=="CANCELLED");
  const activeOp=(ctx.operationalPeriods||[]).find(op=>op.status==="ACTIVE");
  const selectedOp=movement?.operational_period_id||activeOp?.id||"";
  const selectedDept=movement?.department_id||defaultDepartmentId||departments[0]?.id||"";

  return `<div class="logistics-form-grid">
    <div>
      <label>Guest / Party Name</label>
      <input id="logisticsGuestName" value="${esc(movement?.guest_name||"")}" placeholder="Guest name or party name">
    </div>
    <div>
      <label>Group / Organization</label>
      <input id="logisticsGuestGroup" value="${esc(movement?.guest_group||"")}" placeholder="Optional">
    </div>
    <div>
      <label>Party Size</label>
      <input id="logisticsPartySize" type="number" min="1" max="500" value="${movement?.party_size||1}">
    </div>
    <div>
      <label>Movement Type</label>
      <select id="logisticsMovementType">${movementTypeOptions(movement?.movement_type||"OTHER")}</select>
    </div>
    <div>
      <label>Scheduled Time (24-hour)</label>
      <input id="logisticsScheduledAt" inputmode="numeric" value="${esc(dateInputValue(movement?.scheduled_at))}" placeholder="YYYY-MM-DD HH:mm">
    </div>
    <div>
      <label>Operational Period</label>
      <select id="logisticsOperationalPeriod">
        <option value="">No specific period</option>
        ${opOptions.map(op=>`<option value="${op.id}" ${op.id===selectedOp?"selected":""}>${esc(op.name)} · ${esc(op.incident_prefix)}</option>`).join("")}
      </select>
    </div>
    <div>
      <label>Responsible Department</label>
      <select id="logisticsDepartment" ${movement?"disabled":""}>
        ${departments.map(dep=>`<option value="${dep.id}" ${dep.id===selectedDept?"selected":""}>${esc(dep.name)}</option>`).join("")}
      </select>
    </div>
    <div>
      <label>External / Spreadsheet Reference</label>
      <input id="logisticsExternalReference" value="${esc(movement?.external_reference||"")}" placeholder="Optional">
    </div>

    <div class="logistics-form-span">
      <label>Origin / Pickup</label>
      <input id="logisticsOrigin" value="${esc(movement?.origin||"")}" placeholder="Airport, hotel, venue, address...">
    </div>
    <div class="logistics-form-span">
      <label>Destination / Drop-Off</label>
      <input id="logisticsDestination" value="${esc(movement?.destination||"")}" placeholder="Hotel, venue, airport, address...">
    </div>

    <div>
      <label>Airline</label>
      <input id="logisticsAirline" value="${esc(movement?.airline||"")}">
    </div>
    <div>
      <label>Flight Number</label>
      <input id="logisticsFlightNumber" value="${esc(movement?.flight_number||"")}" placeholder="UA1234">
    </div>
    <div>
      <label>Airport</label>
      <input id="logisticsAirport" value="${esc(movement?.airport||"")}" placeholder="ORD">
    </div>
    <div>
      <label>Terminal</label>
      <input id="logisticsTerminal" value="${esc(movement?.terminal||"")}">
    </div>

    <div>
      <label>Contact Phone</label>
      <input id="logisticsContactPhone" value="${esc(movement?.contact_phone||"")}">
    </div>
    <div>
      <label>Contact Email</label>
      <input id="logisticsContactEmail" value="${esc(movement?.contact_email||"")}">
    </div>

    <div class="logistics-form-span">
      <label>Dispatch / Driver Notes</label>
      <textarea id="logisticsNotes" rows="3">${esc(movement?.notes||"")}</textarea>
    </div>
  </div>`;
}

function readMovementForm(){
  const scheduledAt=parseLocalDateTime24(document.querySelector("#logisticsScheduledAt").value);
  if(!scheduledAt)throw new Error("Scheduled Time must use YYYY-MM-DD HH:mm.");

  const partySize=Number.parseInt(document.querySelector("#logisticsPartySize").value,10);
  if(!Number.isFinite(partySize)||partySize<1)throw new Error("Party Size must be at least 1.");

  const guestName=document.querySelector("#logisticsGuestName").value.trim();
  const origin=document.querySelector("#logisticsOrigin").value.trim();
  const destination=document.querySelector("#logisticsDestination").value.trim();

  if(!guestName)throw new Error("Guest / Party Name is required.");
  if(!origin||!destination)throw new Error("Origin and Destination are required.");

  return {
    departmentId:document.querySelector("#logisticsDepartment").value,
    operationalPeriodId:document.querySelector("#logisticsOperationalPeriod").value||null,
    guestName,
    guestGroup:document.querySelector("#logisticsGuestGroup").value.trim()||null,
    partySize,
    scheduledAt,
    movementType:document.querySelector("#logisticsMovementType").value,
    origin,
    destination,
    airline:document.querySelector("#logisticsAirline").value.trim()||null,
    flightNumber:document.querySelector("#logisticsFlightNumber").value.trim()||null,
    airport:document.querySelector("#logisticsAirport").value.trim()||null,
    terminal:document.querySelector("#logisticsTerminal").value.trim()||null,
    contactPhone:document.querySelector("#logisticsContactPhone").value.trim()||null,
    contactEmail:document.querySelector("#logisticsContactEmail").value.trim()||null,
    externalReference:document.querySelector("#logisticsExternalReference").value.trim()||null,
    notes:document.querySelector("#logisticsNotes").value.trim()||null
  };
}

async function movementFormModal(ctx,state,{movement=null,departmentId=null}={}){
  const content=openModal();

  content.innerHTML=`<div class="logistics-modal-header">
    <div>
      <div class="section-title">GUEST LOGISTICS</div>
      <h2>${movement?`Edit ${esc(movement.movement_number)}`:"Add Prescheduled Movement"}</h2>
    </div>
    <button class="logistics-modal-close" id="closeLogisticsModal">×</button>
  </div>

  <div class="logistics-modal-body stack">
    ${movementFormHtml(ctx,movement,departmentId)}
    <div id="logisticsFormError" class="small destructive-error"></div>
  </div>

  <div class="logistics-modal-footer">
    <button class="btn secondary" id="cancelLogisticsForm">Cancel</button>
    <button class="btn" id="saveLogisticsMovement">${movement?"Save Movement":"Add Movement"}</button>
  </div>`;

  document.querySelector("#closeLogisticsModal").onclick=closeModal;
  document.querySelector("#cancelLogisticsForm").onclick=closeModal;

  document.querySelector("#saveLogisticsMovement").onclick=async()=>{
    const button=document.querySelector("#saveLogisticsMovement");
    const errorHost=document.querySelector("#logisticsFormError");
    errorHost.textContent="";

    let form;
    try{
      form=readMovementForm();
    }catch(error){
      errorHost.textContent=error.message;
      return;
    }

    button.disabled=true;
    button.textContent=movement?"Saving…":"Adding…";

    const result=movement
      ?await supabase.rpc("guest_logistics_update_movement",{
          p_movement_id:movement.id,
          p_operational_period_id:form.operationalPeriodId,
          p_guest_name:form.guestName,
          p_guest_group:form.guestGroup,
          p_party_size:form.partySize,
          p_scheduled_at:form.scheduledAt,
          p_movement_type:form.movementType,
          p_origin:form.origin,
          p_destination:form.destination,
          p_airline:form.airline,
          p_flight_number:form.flightNumber,
          p_airport:form.airport,
          p_terminal:form.terminal,
          p_contact_phone:form.contactPhone,
          p_contact_email:form.contactEmail,
          p_external_reference:form.externalReference,
          p_notes:form.notes
        })
      :await supabase.rpc("guest_logistics_create_movement",{
          p_event_id:ctx.eventId,
          p_department_id:form.departmentId,
          p_operational_period_id:form.operationalPeriodId,
          p_guest_name:form.guestName,
          p_guest_group:form.guestGroup,
          p_party_size:form.partySize,
          p_scheduled_at:form.scheduledAt,
          p_movement_type:form.movementType,
          p_origin:form.origin,
          p_destination:form.destination,
          p_airline:form.airline,
          p_flight_number:form.flightNumber,
          p_airport:form.airport,
          p_terminal:form.terminal,
          p_contact_phone:form.contactPhone,
          p_contact_email:form.contactEmail,
          p_external_reference:form.externalReference,
          p_import_source:null,
          p_notes:form.notes
        });

    if(result.error){
      button.disabled=false;
      button.textContent=movement?"Save Movement":"Add Movement";
      errorHost.textContent=result.error.message;
      return;
    }

    closeModal();
    await state.reload();
  };
}

async function movementDetailModal(ctx,state,movementId){
  const movement=state.movements.find(m=>m.id===movementId);
  if(!movement)return;

  const activity=await fetchActivity(movement.id);
  const unit=(ctx.units||[]).find(u=>u.id===movement.assigned_unit_id);
  const department=(ctx.departments||[]).find(d=>d.id===movement.department_id);
  const op=(ctx.operationalPeriods||[]).find(o=>o.id===movement.operational_period_id);
  const actions=nextStatusActions(movement);
  const content=openModal();

  content.innerHTML=`<div class="logistics-modal-header">
    <div>
      <div class="section-title">GUEST MOVEMENT</div>
      <div class="row start">
        <h2>${esc(movement.movement_number)}</h2>
        <span class="badge ${movementStatusClass(movement.status)}">${esc(movementStatusLabel(movement.status))}</span>
      </div>
      <div>${esc(movement.guest_name)}${movement.guest_group?` · ${esc(movement.guest_group)}`:""}</div>
    </div>
    <button class="logistics-modal-close" id="closeLogisticsModal">×</button>
  </div>

  <div class="logistics-modal-body stack">
    <div class="logistics-detail-grid">
      <div><span>Scheduled</span><strong>${esc(dateTime24(movement.scheduled_at))}</strong></div>
      <div><span>Party Size</span><strong>${movement.party_size}</strong></div>
      <div><span>Type</span><strong>${esc(movementTypeLabel(movement.movement_type))}</strong></div>
      <div><span>Department</span><strong>${esc(department?.name||"")}</strong></div>
      <div><span>Operational Period</span><strong>${esc(op?.name||"—")}</strong></div>
      <div><span>Spreadsheet Ref</span><strong>${esc(movement.external_reference||"—")}</strong></div>
      <div><span>Driver Acknowledged</span><strong>${esc(dateTime24(movement.driver_acknowledged_at))}</strong></div>
    </div>

    <div class="logistics-route-detail">
      <div><span>Pickup</span><strong>${esc(movement.origin)}</strong></div>
      <div class="logistics-route-arrow">→</div>
      <div><span>Drop-Off</span><strong>${esc(movement.destination)}</strong></div>
    </div>

    ${(movement.flight_number||movement.airline||movement.airport||movement.terminal)?`
      <section class="incident-info-section">
        <div class="section-title">Flight</div>
        <div class="report-kv-grid">
          <span>Airline</span><strong>${esc(movement.airline||"—")}</strong>
          <span>Flight</span><strong>${esc(movement.flight_number||"—")}</strong>
          <span>Airport</span><strong>${esc(movement.airport||"—")}</strong>
          <span>Terminal</span><strong>${esc(movement.terminal||"—")}</strong>
        </div>
      </section>
    `:""}

    ${(movement.contact_phone||movement.contact_email)?`
      <section class="incident-info-section">
        <div class="section-title">Guest Contact</div>
        <div class="report-kv-grid">
          <span>Phone</span><strong>${movement.contact_phone?`<a href="tel:${esc(movement.contact_phone)}">${esc(movement.contact_phone)}</a>`:"—"}</strong>
          <span>Email</span><strong>${movement.contact_email?`<a href="mailto:${esc(movement.contact_email)}">${esc(movement.contact_email)}</a>`:"—"}</strong>
        </div>
      </section>
    `:""}

    ${movement.notes?`<section class="incident-info-section"><div class="section-title">Notes</div><div class="report-notes">${esc(movement.notes)}</div></section>`:""}

    ${!TERMINAL_STATUSES.has(movement.status)?`
      <section class="incident-info-section logistics-driver-section">
        <div class="section-title">Driver Dispatch</div>
        ${["SCHEDULED","READY","ASSIGNED"].includes(movement.status)?`
          <div class="grid2">
            <select id="logisticsDriverUnit">
              <option value="">Choose driver unit…</option>
              ${driverUnitOptions(ctx,state.movements,movement)}
            </select>
            <button class="btn" id="assignLogisticsDriver">${movement.assigned_unit_id?"Change Driver":"Assign Driver"}</button>
          </div>
        `:""}
        ${movement.assigned_unit_id?`
          <div class="row logistics-current-driver">
            <span>Current Driver: <strong>${esc(unit?.name||"Unknown Unit")}</strong></span>
            ${["SCHEDULED","READY","ASSIGNED"].includes(movement.status)?`<button class="btn secondary compact" id="unassignLogisticsDriver">Unassign</button>`:""}
          </div>
        `:`<div class="small muted">No driver has been preassigned.</div>`}
        <div class="small muted">Driver assignment is a schedule commitment only. The unit remains available for CAD work until the movement begins En Route to Pickup.</div>
      </section>

      <section class="incident-info-section">
        <div class="section-title">Movement Actions</div>
        <div class="logistics-action-grid">
          ${actions.map(([status,label,kind])=>`<button class="btn ${kind==="danger"?"danger":kind==="good"?"good":"secondary"}" data-logistics-status="${status}">${esc(label)}</button>`).join("")||`<div class="small muted">Assign a driver to continue the movement.</div>`}
        </div>
      </section>
    `:""}

    <section class="incident-info-section">
      <div class="row">
        <div class="section-title">Movement History</div>
        ${!TERMINAL_STATUSES.has(movement.status)?`<button class="btn secondary compact" id="editLogisticsMovement">Edit Movement</button>`:""}
      </div>
      <div class="logistics-history">
        ${activity.map(item=>`
          <div>
            <span class="mono">${esc(dateTime24(item.created_at))}</span>
            <strong>${esc(String(item.action||"").replaceAll("_"," "))}</strong>
            ${item.detail?.from||item.detail?.to?`<small>${esc(movementStatusLabel(item.detail?.from))} → ${esc(movementStatusLabel(item.detail?.to))}</small>`:""}
          </div>
        `).join("")||`<div class="small muted">No movement activity yet.</div>`}
      </div>
    </section>
  </div>

  <div class="logistics-modal-footer">
    <button class="btn secondary" id="createRelatedLogisticsCadTask">Create Related CAD Task</button>
    <button class="btn secondary" id="closeLogisticsDetails">Close</button>
  </div>`;

  document.querySelector("#closeLogisticsModal").onclick=closeModal;
  document.querySelector("#closeLogisticsDetails").onclick=closeModal;
  document.querySelector("#createRelatedLogisticsCadTask").onclick=()=>{
    closeModal();
    ctx.onNewCadTask?.(movement.department_id,movement);
  };

  document.querySelector("#editLogisticsMovement")?.addEventListener("click",()=>movementFormModal(ctx,state,{movement}));

  document.querySelector("#assignLogisticsDriver")?.addEventListener("click",async()=>{
    const unitId=document.querySelector("#logisticsDriverUnit").value;
    if(!unitId)return alert("Choose a driver unit.");

    const button=document.querySelector("#assignLogisticsDriver");
    button.disabled=true;
    button.textContent="Assigning…";

    const {error}=await supabase.rpc("guest_logistics_assign_unit",{
      p_movement_id:movement.id,
      p_unit_id:unitId
    });

    if(error){
      button.disabled=false;
      button.textContent=movement.assigned_unit_id?"Change Driver":"Assign Driver";
      return alert(error.message);
    }

    closeModal();
    await state.reload();
  });

  document.querySelector("#unassignLogisticsDriver")?.addEventListener("click",async()=>{
    if(!confirm(`Unassign ${unit?.name||"this driver"} from ${movement.movement_number}?`))return;

    const {error}=await supabase.rpc("guest_logistics_unassign_unit",{
      p_movement_id:movement.id
    });

    if(error)return alert(error.message);

    closeModal();
    await state.reload();
  });

  document.querySelectorAll("[data-logistics-status]").forEach(button=>{
    button.onclick=async()=>{
      const target=button.dataset.logisticsStatus;
      if(["CANCELLED","NO_SHOW"].includes(target)){
        const verb=target==="NO_SHOW"?"mark this guest as a No Show":"cancel this movement";
        if(!confirm(`Confirm you want to ${verb}?`))return;
      }

      button.disabled=true;
      const original=button.textContent;
      button.textContent="Updating…";

      const {error}=await supabase.rpc("guest_logistics_set_status",{
        p_movement_id:movement.id,
        p_status:target
      });

      if(error){
        button.disabled=false;
        button.textContent=original;
        return alert(error.message);
      }

      closeModal();
      await state.reload();
    };
  });
}

function downloadTemplate(){
  const headers=[
    "guest_name",
    "guest_group",
    "party_size",
    "scheduled_time",
    "movement_type",
    "origin",
    "destination",
    "airline",
    "flight_number",
    "airport",
    "terminal",
    "contact_phone",
    "contact_email",
    "external_reference",
    "operational_period",
    "notes"
  ];

  const example=[
    "Jane Guest",
    "Featured Speaker",
    "2",
    "2026-08-09 14:30",
    "AIRPORT_ARRIVAL",
    "ORD Terminal 1",
    "Convention Hotel",
    "United",
    "UA1234",
    "ORD",
    "1",
    "",
    "",
    "SHEET-001",
    "",
    "Meet at baggage claim"
  ];

  const csv=[
    headers.map(csvEscape).join(","),
    example.map(csvEscape).join(",")
  ].join("\n");

  const href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));
  const link=document.createElement("a");
  link.href=href;
  link.download="commcenter-guest-logistics-template.csv";
  link.click();
  setTimeout(()=>URL.revokeObjectURL(href),0);
}

async function importModal(ctx,state,defaultDepartmentId=null){
  const departments=logisticsDepartments(ctx);
  const content=openModal();

  content.innerHTML=`<div class="logistics-modal-header">
    <div>
      <div class="section-title">GUEST LOGISTICS</div>
      <h2>Import Prescheduled Transportation</h2>
    </div>
    <button class="logistics-modal-close" id="closeLogisticsModal">×</button>
  </div>

  <div class="logistics-modal-body stack">
    <div class="notice">
      Export your spreadsheet as CSV. Recommended scheduled-time format:
      <strong class="mono">YYYY-MM-DD HH:mm</strong>.
    </div>

    <div class="grid2">
      <div>
        <label>Responsible Department</label>
        <select id="logisticsImportDepartment">
          ${departments.map(dep=>`<option value="${dep.id}" ${dep.id===defaultDepartmentId?"selected":""}>${esc(dep.name)}</option>`).join("")}
        </select>
      </div>
      <div>
        <label>CSV File</label>
        <input id="logisticsImportFile" type="file" accept=".csv,text/csv">
      </div>
    </div>

    <div class="small muted">
      Required columns: guest_name, scheduled_time, origin, destination.
      Optional columns include guest_group, party_size, movement_type, airline,
      flight_number, airport, terminal, contact_phone, contact_email,
      external_reference, operational_period and notes.
    </div>

    <div id="logisticsImportPreview"></div>
    <div id="logisticsImportError" class="small destructive-error"></div>
  </div>

  <div class="logistics-modal-footer">
    <button class="btn secondary" id="downloadLogisticsTemplate">Download Template</button>
    <button class="btn secondary" id="cancelLogisticsImport">Cancel</button>
    <button class="btn" id="confirmLogisticsImport" disabled>Import Movements</button>
  </div>`;

  let preparedRows=[];
  let sourceName="CSV Import";

  const close=closeModal;
  document.querySelector("#closeLogisticsModal").onclick=close;
  document.querySelector("#cancelLogisticsImport").onclick=close;
  document.querySelector("#downloadLogisticsTemplate").onclick=downloadTemplate;

  document.querySelector("#logisticsImportFile").onchange=async event=>{
    const file=event.target.files?.[0];
    if(!file)return;

    sourceName=file.name;
    const text=await file.text();
    const parsed=mapCsvRows(text,ctx);
    preparedRows=parsed.errors.length?[]:parsed.rows;

    const preview=document.querySelector("#logisticsImportPreview");
    const errorHost=document.querySelector("#logisticsImportError");
    const confirmButton=document.querySelector("#confirmLogisticsImport");

    errorHost.textContent=parsed.errors.join(" ");
    confirmButton.disabled=!preparedRows.length;

    preview.innerHTML=parsed.rows.length?`
      <div class="section-title">Preview · ${parsed.rows.length} movement${parsed.rows.length===1?"":"s"}</div>
      <div class="logistics-import-preview">
        ${parsed.rows.slice(0,20).map(row=>`
          <div>
            <span class="mono">${esc(dateTime24(row.scheduled_at))}</span>
            <strong>${esc(row.guest_name)}</strong>
            <span>${esc(row.origin)} → ${esc(row.destination)}</span>
          </div>
        `).join("")}
      </div>
      ${parsed.rows.length>20?`<div class="small muted">Showing first 20 rows.</div>`:""}
    `:"";
  };

  document.querySelector("#confirmLogisticsImport").onclick=async()=>{
    if(!preparedRows.length)return;

    const departmentId=document.querySelector("#logisticsImportDepartment").value;
    const button=document.querySelector("#confirmLogisticsImport");
    button.disabled=true;
    button.textContent=`Importing ${preparedRows.length}…`;

    const {data,error}=await supabase.rpc("guest_logistics_import_movements",{
      p_event_id:ctx.eventId,
      p_department_id:departmentId,
      p_rows:preparedRows,
      p_source:sourceName
    });

    if(error){
      button.disabled=false;
      button.textContent="Import Movements";
      document.querySelector("#logisticsImportError").textContent=error.message;
      return;
    }

    closeModal();
    await state.reload();
    alert(`Imported ${data} guest movement${Number(data)===1?"":"s"}.`);
  };
}

function movementExportColumns(ctx){
  return [
    {label:"Movement",value:"movement_number"},
    {label:"Scheduled",value:r=>dateTime24(r.scheduled_at)},
    {label:"Status",value:r=>movementStatusLabel(r.status)},
    {label:"Type",value:r=>movementTypeLabel(r.movement_type)},
    {label:"Guest / Party",value:"guest_name"},
    {label:"Group",value:"guest_group"},
    {label:"Party Size",value:"party_size"},
    {label:"Origin",value:"origin"},
    {label:"Destination",value:"destination"},
    {label:"Airline",value:"airline"},
    {label:"Flight",value:"flight_number"},
    {label:"Airport",value:"airport"},
    {label:"Terminal",value:"terminal"},
    {label:"Driver",value:r=>(ctx.units||[]).find(u=>u.id===r.assigned_unit_id)?.name||""},
    {label:"Assigned",value:r=>dateTime24(r.assigned_at)},
    {label:"Driver Acknowledged",value:r=>dateTime24(r.driver_acknowledged_at)},
    {label:"En Route Pickup",value:r=>dateTime24(r.en_route_pickup_at)},
    {label:"At Pickup",value:r=>dateTime24(r.at_pickup_at)},
    {label:"Guest On Board",value:r=>dateTime24(r.passenger_onboard_at)},
    {label:"En Route Destination",value:r=>dateTime24(r.en_route_destination_at)},
    {label:"Completed",value:r=>dateTime24(r.completed_at)},
    {label:"No Show",value:r=>dateTime24(r.no_show_at)},
    {label:"Cancelled",value:r=>dateTime24(r.cancelled_at)},
    {label:"Contact Phone",value:"contact_phone"},
    {label:"Contact Email",value:"contact_email"},
    {label:"External Reference",value:"external_reference"},
    {label:"Notes",value:"notes"}
  ];
}

export async function renderGuestLogistics(app,ctx){
  if(logisticsChannel){
    try{await supabase.removeChannel(logisticsChannel);}catch{}
    logisticsChannel=null;
  }

  const departments=logisticsDepartments(ctx);

  if(!departments.length){
    app.innerHTML=`<div class="shell">${ctx.header(`${esc(ctx.event?.name||"Event")} · Guest Logistics`)}
      <div class="center"><div class="card stack">
        <h2>Guest Logistics is not enabled</h2>
        <p class="muted">Enable Guest Logistics on the appropriate department in Event Admin → Setup → Edit Department.</p>
        <button class="btn secondary" id="backGuestLogistics">Back to Dispatch</button>
      </div></div>
    </div>`;
    document.querySelector("#backGuestLogistics").onclick=ctx.onBack;
    return;
  }

  const state={
    movements:[],
    reload:null
  };

  const render=()=>{
    const departmentFilter=document.querySelector("#logisticsDepartmentFilter")?.value||"";
    const statusFilter=document.querySelector("#logisticsStatusFilter")?.value||"OPEN";
    const search=(document.querySelector("#logisticsSearch")?.value||"").trim().toLowerCase();
    const dateFilter=document.querySelector("#logisticsDateFilter")?.value||"";

    const filtered=state.movements.filter(movement=>{
      if(departmentFilter&&movement.department_id!==departmentFilter)return false;
      if(statusFilter==="OPEN"&&TERMINAL_STATUSES.has(movement.status))return false;
      if(statusFilter==="CLOSED"&&!TERMINAL_STATUSES.has(movement.status))return false;
      if(statusFilter&&!["OPEN","CLOSED","ALL"].includes(statusFilter)&&movement.status!==statusFilter)return false;
      if(dateFilter){
        const d=new Date(movement.scheduled_at);
        const pad=n=>String(n).padStart(2,"0");
        const local=`${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
        if(local!==dateFilter)return false;
      }
      if(search&&!movementSearchText(movement,ctx).includes(search))return false;
      return true;
    });

    document.querySelector("#guestLogisticsList").innerHTML=
      filtered.map(movement=>movementCard(movement,ctx)).join("")
      ||`<div class="card"><div class="muted">No movements match the current filters.</div></div>`;

    const now=Date.now();
    const active=state.movements.filter(m=>["ASSIGNED","EN_ROUTE_PICKUP","AT_PICKUP","PASSENGER_ONBOARD","EN_ROUTE_DESTINATION"].includes(m.status));
    const upcoming=state.movements.filter(m=>!TERMINAL_STATUSES.has(m.status)&&new Date(m.scheduled_at).getTime()>=now);
    const unassigned=state.movements.filter(m=>!TERMINAL_STATUSES.has(m.status)&&!m.assigned_unit_id);
    const completed=state.movements.filter(m=>m.status==="COMPLETE");

    document.querySelector("#logisticsMetricUpcoming").textContent=upcoming.length;
    document.querySelector("#logisticsMetricActive").textContent=active.length;
    document.querySelector("#logisticsMetricUnassigned").textContent=unassigned.length;
    document.querySelector("#logisticsMetricComplete").textContent=completed.length;

    document.querySelectorAll("[data-logistics-open]").forEach(button=>{
      button.onclick=()=>movementDetailModal(ctx,state,button.dataset.logisticsOpen);
    });
  };

  state.reload=async()=>{
    state.movements=await fetchMovements(ctx.eventId);
    render();
  };

  const allowedDeptIds=new Set(
    (ctx.dispatchDepartmentIds||[]).filter(id=>departments.some(dep=>dep.id===id))
  );
  const defaultDepartmentId=[...allowedDeptIds][0]||departments[0].id;

  const openCadIncidents=(ctx.incidents||[]).filter(incident=>
    (incident.incident_departments||[]).some(link=>
      departments.some(dep=>dep.id===link.department_id)
    )
  );

  app.innerHTML=`<div class="shell">${ctx.header(`${esc(ctx.event?.name||"Event")} · Guest Logistics`)}
    <div class="logistics-shell stack">
      <div class="logistics-header card">
        <div class="row">
          <div>
            <div class="section-title">SPECIAL GUEST MOVEMENT</div>
            <h2>Guest Logistics</h2>
            <p class="muted">Prescheduled airport, hotel and venue transportation shares the same units and field devices as CommCenter CAD without turning every scheduled ride into a CAD incident.</p>
          </div>
          <div class="nav">
            <button class="btn" id="addGuestMovement">+ Add Movement</button>
            <button class="btn secondary" id="importGuestMovements">Import CSV</button>
            <button class="btn secondary" id="guestLogisticsTemplate">CSV Template</button>
            <button class="btn secondary" id="exportGuestMovements">Export Movement Log</button>
            <button class="btn secondary" id="backGuestLogistics">Back to Dispatch</button>
          </div>
        </div>
      </div>

      <div class="ems-metrics logistics-metrics">
        <div class="card"><div class="metric" id="logisticsMetricUpcoming">0</div><div class="small muted">Upcoming</div></div>
        <div class="card"><div class="metric" id="logisticsMetricActive">0</div><div class="small muted">Active Moves</div></div>
        <div class="card"><div class="metric" id="logisticsMetricUnassigned">0</div><div class="small muted">Need Driver</div></div>
        <div class="card"><div class="metric" id="logisticsMetricComplete">0</div><div class="small muted">Completed</div></div>
      </div>

      <div class="card logistics-cad-task-card">
        <div class="row">
          <div>
            <div class="section-title">AD-HOC OPERATIONS</div>
            <strong>Guest Logistics CAD Tasks</strong>
            <div class="small muted">Errands, special requests and unscheduled operational tasks should remain normal CAD incidents.</div>
          </div>
          <button class="btn secondary" id="newGuestLogisticsCadTask">+ New Logistics CAD Task</button>
        </div>
        ${openCadIncidents.length?`
          <div class="logistics-open-cad-tasks">
            ${openCadIncidents.map(incident=>`
              <button class="choice" data-logistics-cad="${incident.id}">
                <strong>${esc(incident.incident_number)}</strong>
                <span>${esc(incident.call_type)}</span>
                <small>${esc(incident.landmark||"")}</small>
              </button>
            `).join("")}
          </div>
        `:""}
      </div>

      <div class="card logistics-filters">
        <div>
          <label>Department</label>
          <select id="logisticsDepartmentFilter">
            <option value="">All Guest Logistics Departments</option>
            ${departments.map(dep=>`<option value="${dep.id}" ${dep.id===defaultDepartmentId?"selected":""}>${esc(dep.name)}</option>`).join("")}
          </select>
        </div>
        <div>
          <label>Status</label>
          <select id="logisticsStatusFilter">
            <option value="OPEN">Open / Upcoming</option>
            <option value="ALL">All Statuses</option>
            <option value="SCHEDULED">Scheduled</option>
            <option value="READY">Ready</option>
            <option value="ASSIGNED">Driver Assigned</option>
            <option value="EN_ROUTE_PICKUP">En Route Pickup</option>
            <option value="AT_PICKUP">At Pickup</option>
            <option value="PASSENGER_ONBOARD">Guest On Board</option>
            <option value="EN_ROUTE_DESTINATION">En Route Destination</option>
            <option value="CLOSED">Completed / Closed</option>
          </select>
        </div>
        <div>
          <label>Date</label>
          <input id="logisticsDateFilter" type="date">
        </div>
        <div class="logistics-search-filter">
          <label>Search</label>
          <input id="logisticsSearch" placeholder="Guest, flight, route, driver, reference…">
        </div>
      </div>

      <div id="guestLogisticsList" class="logistics-movement-list">
        <div class="card"><div class="muted">Loading guest movements…</div></div>
      </div>
    </div>
  </div>`;

  document.querySelector("#backGuestLogistics").onclick=async()=>{
    if(logisticsChannel){
      try{await supabase.removeChannel(logisticsChannel);}catch{}
      logisticsChannel=null;
    }
    ctx.onBack();
  };

  document.querySelector("#addGuestMovement").onclick=()=>movementFormModal(ctx,state,{departmentId:defaultDepartmentId});
  document.querySelector("#importGuestMovements").onclick=()=>importModal(ctx,state,defaultDepartmentId);
  document.querySelector("#guestLogisticsTemplate").onclick=downloadTemplate;

  document.querySelector("#exportGuestMovements").onclick=()=>{
    downloadCsv(
      `${ctx.event?.event_code||"event"}-guest-logistics.csv`,
      movementExportColumns(ctx),
      state.movements
    );
  };

  document.querySelector("#newGuestLogisticsCadTask").onclick=()=>{
    const selected=document.querySelector("#logisticsDepartmentFilter").value||defaultDepartmentId;
    ctx.onNewCadTask?.(selected);
  };

  document.querySelectorAll("[data-logistics-cad]").forEach(button=>{
    button.onclick=()=>ctx.onOpenIncident?.(button.dataset.logisticsCad);
  });

  for(const id of ["logisticsDepartmentFilter","logisticsStatusFilter","logisticsDateFilter"]){
    document.querySelector(`#${id}`).addEventListener("change",render);
  }
  document.querySelector("#logisticsSearch").addEventListener("input",render);

  try{
    await state.reload();
  }catch(error){
    document.querySelector("#guestLogisticsList").innerHTML=`<div class="notice error">${esc(error.message)}</div>`;
    return;
  }

  logisticsChannel=supabase.channel(`guest-logistics-${ctx.eventId}-${Date.now()}`)
    .on("postgres_changes",{
      event:"*",
      schema:"public",
      table:"guest_logistics_movements",
      filter:`event_id=eq.${ctx.eventId}`
    },()=>state.reload().catch(console.warn))
    .subscribe();
}

export async function loadFieldLogisticsState(eventId,unitId){
  const {data,error}=await supabase.from("guest_logistics_movements")
    .select("*")
    .eq("event_id",eventId)
    .eq("assigned_unit_id",unitId)
    .not("status","in","(COMPLETE,NO_SHOW,CANCELLED)")
    .order("scheduled_at");

  if(error)throw error;

  const rows=data||[];
  const underwayStatuses=["EN_ROUTE_PICKUP","AT_PICKUP","PASSENGER_ONBOARD","EN_ROUTE_DESTINATION"];
  const current=rows.find(row=>underwayStatuses.includes(row.status))||rows[0]||null;

  return {
    current,
    underway:!!current&&underwayStatuses.includes(current.status),
    upcoming:rows
  };
}

function fieldNextActions(movement){
  if(!movement)return [];
  switch(movement.status){
    case "ASSIGNED":
    case "READY":
      return [["EN_ROUTE_PICKUP","En Route to Pickup","good"]];
    case "EN_ROUTE_PICKUP":
      return [["AT_PICKUP","Arrived at Pickup","good"]];
    case "AT_PICKUP":
      return [
        ["PASSENGER_ONBOARD","Guest On Board","good"],
        ["NO_SHOW","No Show","danger"]
      ];
    case "PASSENGER_ONBOARD":
      return [["EN_ROUTE_DESTINATION","En Route to Destination","good"]];
    case "EN_ROUTE_DESTINATION":
      return [["COMPLETE","Arrived / Complete","good"]];
    default:
      return [];
  }
}

export function fieldLogisticsPanelHtml(state){
  const movement=state?.current;
  if(!movement)return "";

  const flight=[movement.airline,movement.flight_number].filter(Boolean).join(" ");

  return `<div class="card field-logistics-card">
    <div class="row">
      <div>
        <div class="section-title">GUEST LOGISTICS MOVEMENT</div>
        <div class="row start">
          <strong class="big">${esc(movement.movement_number)}</strong>
          <span class="badge ${movementStatusClass(movement.status)}">${esc(movementStatusLabel(movement.status))}</span>
        </div>
      </div>
      <div class="field-logistics-scheduled">
        <span>Scheduled</span>
        <strong class="mono">${esc(dateTime24(movement.scheduled_at))}</strong>
      </div>
    </div>

    <div class="field-logistics-guest">
      <strong>${esc(movement.guest_name)}</strong>
      <span>${movement.guest_group?`${esc(movement.guest_group)} · `:""}${movement.party_size} pax</span>
    </div>

    <div class="field-logistics-route">
      <div><span>Pickup</span><strong>${esc(movement.origin)}</strong></div>
      <div class="logistics-route-arrow">→</div>
      <div><span>Destination</span><strong>${esc(movement.destination)}</strong></div>
    </div>

    ${flight||movement.airport||movement.terminal?`
      <div class="small field-logistics-flight">
        ${flight?`<strong>${esc(flight)}</strong>`:""}
        ${movement.airport?` · ${esc(movement.airport)}`:""}
        ${movement.terminal?` · Terminal ${esc(movement.terminal)}`:""}
      </div>
    `:""}

    ${movement.contact_phone?`
      <a class="btn secondary compact field-logistics-contact" href="tel:${esc(movement.contact_phone)}">Call Guest / Contact</a>
    `:""}

    ${movement.notes?`<div class="notice">${esc(movement.notes)}</div>`:""}

    ${state?.blockedByCad&&!state?.underway?`
      <div class="notice">
        <strong>CAD assignment in progress.</strong><br>
        This guest movement is preassigned to your unit, but it cannot begin until the current CAD incident is cleared.
      </div>
    `:""}

    ${!movement.driver_acknowledged_at&&["ASSIGNED","READY"].includes(movement.status)?`
      <button class="btn secondary block" id="fieldAcknowledgeGuestMovement">Acknowledge Assignment</button>
    `:movement.driver_acknowledged_at?`
      <div class="small logistics-field-ack">Acknowledged ${esc(dateTime24(movement.driver_acknowledged_at))}</div>
    `:""}

    <div class="logistics-action-grid field-logistics-actions">
      ${state?.blockedByCad&&!state?.underway
        ?``
        :fieldNextActions(movement).map(([status,label,kind])=>`
          <button class="btn ${kind==="danger"?"danger":"good"}" data-field-logistics-status="${status}">${esc(label)}</button>
        `).join("")}
    </div>

    ${Array.isArray(state?.upcoming)&&state.upcoming.length>1?`
      <div class="small muted">Additional preassigned trips: ${state.upcoming.length-1}</div>
    `:""}
  </div>`;
}

export function bindFieldLogisticsPanel(state,{refresh}){
  const movement=state?.current;
  if(!movement)return;

  document.querySelector("#fieldAcknowledgeGuestMovement")?.addEventListener("click",async()=>{
    const button=document.querySelector("#fieldAcknowledgeGuestMovement");
    button.disabled=true;
    button.textContent="Acknowledging…";

    const {error}=await supabase.rpc("guest_logistics_acknowledge_movement",{
      p_movement_id:movement.id
    });

    if(error){
      button.disabled=false;
      button.textContent="Acknowledge Assignment";
      return alert(error.message);
    }

    await refresh();
  });

  if(state?.blockedByCad&&!state?.underway)return;

  document.querySelectorAll("[data-field-logistics-status]").forEach(button=>{
    button.onclick=async()=>{
      const status=button.dataset.fieldLogisticsStatus;
      if(status==="NO_SHOW"&&!confirm("Confirm the guest / party is a No Show?"))return;

      button.disabled=true;
      const original=button.textContent;
      button.textContent="Updating…";

      const {error}=await supabase.rpc("guest_logistics_set_status",{
        p_movement_id:movement.id,
        p_status:status
      });

      if(error){
        button.disabled=false;
        button.textContent=original;
        return alert(error.message);
      }

      await refresh();
    };
  });
}
