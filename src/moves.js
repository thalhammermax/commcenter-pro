/* CommCenter Pro v0.18.0 — Guest Logistics on the unified incident model.
   A MOVE is an incident with incident_kind='MOVE'. This module provides the
   MOVE adapter, intake form, board, CSV import/export and the Field Unit
   panel. Status lives on incident_units.cad_status like every other ticket. */
import { supabase } from "./supabase.js";

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]));

export const MOVE_TERMINAL_STATUSES=new Set(["COMPLETE","NO_SHOW","CANCELLED"]);
export const MOVE_UNDERWAY_STATUSES=new Set(["EN_ROUTE_PICKUP","AT_PICKUP","PASSENGER_ONBOARD","EN_ROUTE_DESTINATION"]);
export const MOVE_TYPES=["AIRPORT_ARRIVAL","AIRPORT_DEPARTURE","HOTEL_TRANSFER","VENUE_TRANSFER","LOCAL_TRANSFER","OTHER"];

function dateTime24(value){
  if(!value)return "—";
  const d=new Date(value);
  if(Number.isNaN(d.getTime()))return "—";
  return d.toLocaleString([],{year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hour12:false,hourCycle:"h23"});
}
function time24(value){
  if(!value)return "—";
  const d=new Date(value);
  if(Number.isNaN(d.getTime()))return "—";
  return d.toLocaleTimeString([],{hour:"2-digit",minute:"2-digit",hour12:false,hourCycle:"h23"});
}
function dateInputValue(value){
  if(!value)return "";
  const d=new Date(value);
  if(Number.isNaN(d.getTime()))return "";
  const pad=n=>String(n).padStart(2,"0");
  return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function parseLocalDateTime24(raw){
  const value=String(raw||"").trim();
  if(!value)return null;
  let match=value.match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/);
  if(match){
    const [,year,month,day,hour,minute]=match;
    const d=new Date(Number(year),Number(month)-1,Number(day),Number(hour),Number(minute),0,0);
    if(d.getFullYear()!==Number(year)||d.getMonth()!==Number(month)-1||d.getDate()!==Number(day)||d.getHours()!==Number(hour)||d.getMinutes()!==Number(minute))return null;
    return d.toISOString();
  }
  if(/^\d{4}-\d{2}-\d{2}T/.test(value)){
    const d=new Date(value);
    if(!Number.isNaN(d.getTime()))return d.toISOString();
  }
  return null;
}

export function movementTypeLabel(type){
  return ({AIRPORT_ARRIVAL:"Airport Arrival",AIRPORT_DEPARTURE:"Airport Departure",HOTEL_TRANSFER:"Hotel Transfer",VENUE_TRANSFER:"Venue Transfer",LOCAL_TRANSFER:"Local Transfer",OTHER:"Other Movement"})[type]||String(type||"Movement").replaceAll("_"," ");
}
export function movementStatusLabel(status){
  return ({
    SCHEDULED:"Scheduled",READY:"Active · No Driver",ASSIGNED:"Driver Assigned",
    EN_ROUTE_PICKUP:"En Route to Pickup",AT_PICKUP:"At Pickup",PASSENGER_ONBOARD:"Guest On Board",
    EN_ROUTE_DESTINATION:"En Route to Destination",COMPLETE:"Complete",NO_SHOW:"No Show",CANCELLED:"Cancelled"
  })[status]||String(status||"").replaceAll("_"," ");
}
export function movementStatusClass(status){
  return `logistics-status-${String(status||"").toLowerCase().replaceAll("_","-")}`;
}

/* Adapt a MOVE incident (with incident_guest_details + incident_units) into the
   flat shape every board, card and tooltip renders. */
export function moveFromIncident(incident){
  if(!incident||incident.incident_kind!=="MOVE")return null;
  const g=Array.isArray(incident.incident_guest_details)?incident.incident_guest_details[0]:incident.incident_guest_details;
  const link=(incident.incident_units||[]).find(l=>!l.cleared_at)||null;
  let status;
  if(incident.status==="CLOSED")status=incident.disposition||"COMPLETE";
  else if(incident.status==="SCHEDULED")status="SCHEDULED";
  else status=link?(link.cad_status||"ASSIGNED"):"READY";
  return {
    id:incident.id,
    incident,
    link,
    event_id:incident.event_id,
    department_id:(incident.incident_departments||[])[0]?.department_id||null,
    movement_number:incident.incident_number,
    movement_type:g?.movement_type||"OTHER",
    guest_name:g?.guest_name||incident.call_type||"Guest",
    guest_group:g?.guest_group||null,
    party_size:g?.party_size||1,
    contact_phone:g?.contact_phone||null,
    contact_email:g?.contact_email||null,
    origin:g?.origin||incident.landmark||"",
    destination:g?.destination||"",
    airline:g?.airline||null,
    flight_number:g?.flight_number||null,
    airport:g?.airport||null,
    terminal:g?.terminal||null,
    notes:incident.notes||null,
    priority:incident.priority,
    status,
    incident_status:incident.status,
    scheduled_at:incident.scheduled_at,
    activated_at:incident.activated_at,
    assigned_unit_id:link?.unit_id||null,
    assigned_at:link?.assigned_at||null,
    driver_acknowledged_at:link?.acknowledged_at||null,
    is_primary:!!link?.is_primary,
    queue_position:link?.queue_position||null,
    primary_acknowledged_at:link?.primary_acknowledged_at||null,
    updated_at:link?.cad_status_updated_at||incident.activated_at||incident.created_at
  };
}

const RISK_ACK_GRACE_MS=3*60*1000;
const RISK_LEAD_MS=15*60*1000;
export function movementRisk(m,now=Date.now()){
  if(!m||MOVE_TERMINAL_STATUSES.has(m.status)||m.incident_status==="CLOSED")return null;
  const scheduled=new Date(m.scheduled_at||0).getTime();
  if(!Number.isFinite(scheduled)||!scheduled)return null;
  if(["PASSENGER_ONBOARD","EN_ROUTE_DESTINATION"].includes(m.status))return null;
  const minutesLate=Math.floor((now-scheduled)/60000);
  if(now>scheduled){
    if(m.status==="AT_PICKUP")return {level:"risk",label:"WAITING AT PICKUP"};
    return {level:"late",label:minutesLate>=1?`${minutesLate}m LATE`:"LATE"};
  }
  const soon=scheduled-now<=RISK_LEAD_MS;
  if(!m.assigned_unit_id&&soon)return {level:"risk",label:"NO DRIVER"};
  if(m.assigned_unit_id&&!m.driver_acknowledged_at&&m.assigned_at&&now-new Date(m.assigned_at).getTime()>RISK_ACK_GRACE_MS)return {level:"risk",label:"NO DRIVER ACK"};
  return null;
}

/* Next MOVE status actions for the assigned driver / Dispatch. */
export function moveStatusActions(move){
  if(!move||!move.assigned_unit_id)return [];
  switch(move.status){
    case "SCHEDULED":
    case "ASSIGNED":return [["EN_ROUTE_PICKUP","En Route to Pickup","good"]];
    case "EN_ROUTE_PICKUP":return [["AT_PICKUP","Arrived at Pickup","good"]];
    case "AT_PICKUP":return [["PASSENGER_ONBOARD","Guest On Board","good"],["NO_SHOW","No Show","danger"]];
    case "PASSENGER_ONBOARD":return [["EN_ROUTE_DESTINATION","En Route to Destination","good"]];
    case "EN_ROUTE_DESTINATION":return [["COMPLETE","Arrived / Complete","good"]];
    default:return [];
  }
}

export async function setMoveStatus(incidentId,unitId,status){
  const {error}=await supabase.rpc("set_move_status",{p_incident_id:incidentId,p_unit_id:unitId,p_status:status,p_client_time:new Date().toISOString()});
  if(error)throw error;
}

/* ---------------- intake form ---------------- */

function moveTypeOptions(selected="OTHER"){
  return MOVE_TYPES.map(t=>`<option value="${t}" ${t===selected?"selected":""}>${esc(movementTypeLabel(t))}</option>`).join("");
}

function moveFormHtml(ctx,move,defaultDepartmentId){
  const departments=(ctx.departments||[]).filter(d=>d.active!==false&&d.guest_logistics_enabled===true);
  const deptId=move?.department_id||defaultDepartmentId||departments[0]?.id||"";
  const drivers=(ctx.units||[]).filter(u=>u.active!==false&&departments.some(d=>d.id===u.department_id));
  return `<div class="stack move-form">
    <div class="grid2">
      <div><label>Department</label><select id="mvDepartment">${departments.map(d=>`<option value="${d.id}" ${d.id===deptId?"selected":""}>${esc(d.short_name||d.name)}</option>`).join("")}</select></div>
      <div><label>Movement type</label><select id="mvType">${moveTypeOptions(move?.movement_type)}</select></div>
    </div>
    <div class="grid2">
      <div><label>Scheduled pickup</label><input id="mvScheduled" type="datetime-local" value="${esc(dateInputValue(move?.scheduled_at))}" required></div>
      <div><label>Priority</label><select id="mvPriority">${["Standard","Elevated","Urgent"].map(p=>`<option ${p===(move?.priority||"Standard")?"selected":""}>${p}</option>`).join("")}</select></div>
    </div>
    <div class="grid2">
      <div><label>Guest / party name</label><input id="mvGuest" value="${esc(move?.guest_name||"")}" required></div>
      <div><label>Group / organization</label><input id="mvGroup" value="${esc(move?.guest_group||"")}"></div>
    </div>
    <div class="grid2">
      <div><label>Party size</label><input id="mvParty" type="number" min="1" max="500" value="${esc(move?.party_size||1)}"></div>
      <div><label>Contact phone</label><input id="mvPhone" value="${esc(move?.contact_phone||"")}"></div>
    </div>
    <div class="grid2">
      <div><label>Pickup location</label><input id="mvOrigin" value="${esc(move?.origin||"")}" required></div>
      <div><label>Destination</label><input id="mvDestination" value="${esc(move?.destination||"")}" required></div>
    </div>
    <div class="grid2">
      <div><label>Airline</label><input id="mvAirline" value="${esc(move?.airline||"")}"></div>
      <div><label>Flight number</label><input id="mvFlight" value="${esc(move?.flight_number||"")}"></div>
    </div>
    <div class="grid2">
      <div><label>Airport</label><input id="mvAirport" value="${esc(move?.airport||"")}"></div>
      <div><label>Terminal</label><input id="mvTerminal" value="${esc(move?.terminal||"")}"></div>
    </div>
    <div><label>Contact email</label><input id="mvEmail" value="${esc(move?.contact_email||"")}"></div>
    <div><label>Driver notes</label><textarea id="mvNotes" rows="3">${esc(move?.notes||"")}</textarea></div>
    ${move?"":`<div class="grid2">
      <div><label>Activate on board</label><select id="mvLead">${[30,60,90,120].map(n=>`<option value="${n}" ${n===60?"selected":""}>${n} min before pickup</option>`).join("")}</select></div>
      <div><label>Assign driver now (optional)</label><select id="mvDriver"><option value="">No driver yet</option>${drivers.map(u=>`<option value="${u.id}">${esc(u.name)}</option>`).join("")}</select></div>
    </div>`}
  </div>`;
}

function readMoveForm(){
  const v=id=>document.querySelector(`#${id}`)?.value?.trim()||"";
  const scheduledRaw=v("mvScheduled");
  const scheduled=scheduledRaw?new Date(scheduledRaw):null;
  return {
    department_id:v("mvDepartment")||null,
    scheduled_at:scheduled&&!Number.isNaN(scheduled.getTime())?scheduled.toISOString():null,
    priority:v("mvPriority")||"Standard",
    notes:v("mvNotes")||null,
    lead:Number(v("mvLead")||60),
    assign_unit_id:v("mvDriver")||null,
    guest:{
      movement_type:v("mvType")||"OTHER",guest_name:v("mvGuest"),guest_group:v("mvGroup")||null,
      party_size:Number(v("mvParty")||1),contact_phone:v("mvPhone")||null,contact_email:v("mvEmail")||null,
      origin:v("mvOrigin"),destination:v("mvDestination"),airline:v("mvAirline")||null,
      flight_number:v("mvFlight")||null,airport:v("mvAirport")||null,terminal:v("mvTerminal")||null
    }
  };
}

/* ctx.openModal() returns the modal content host; ctx.closeModal() closes it. */
export function moveFormModal(ctx,{move=null,departmentId=null,onSaved}={}){
  const content=ctx.openModal("move-form");
  content.__ccHtml=null;
  content.innerHTML=`<div class="incident-modal-header">
    <div><div class="incident-modal-eyebrow">GUEST LOGISTICS</div><h2 id="incidentModalTitle">${move?`Edit ${esc(move.movement_number)}`:"New MOVE"}</h2>
    <div class="incident-modal-nature">${move?esc(move.guest_name):"Scheduled guest transportation ticket"}</div></div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close">×</button></div>
    <div style="padding:18px">${moveFormHtml(ctx,move,departmentId)}</div>
    <div class="incident-modal-footer"><div class="grid2">
      <button class="btn" id="saveMove">${move?"Save Changes":"Create MOVE"}</button>
      <button class="btn secondary" id="cancelMove">Cancel</button>
    </div></div>`;
  const close=()=>{ctx.closeModal();if(move&&ctx.onOpenIncident)ctx.onOpenIncident(move.id);};
  document.querySelector("#closeIncidentModal").onclick=close;
  document.querySelector("#cancelMove").onclick=close;
  document.querySelector("#saveMove").onclick=async()=>{
    const f=readMoveForm();
    if(!f.guest.guest_name)return alert("Guest name is required.");
    if(!f.scheduled_at)return alert("Scheduled pickup time is required.");
    if(!f.guest.origin||!f.guest.destination)return alert("Pickup and destination are required.");
    const button=document.querySelector("#saveMove");
    button.disabled=true;button.textContent="Saving…";
    const res=move
      ?await supabase.rpc("update_move_incident",{p_incident_id:move.id,p_scheduled_at:f.scheduled_at,p_guest:f.guest,p_notes:f.notes,p_priority:f.priority,p_department_id:f.department_id})
      :await supabase.rpc("create_move_incident",{p_event_id:ctx.eventId,p_department_id:f.department_id,p_scheduled_at:f.scheduled_at,p_guest:f.guest,p_notes:f.notes,p_priority:f.priority,p_activate_lead_minutes:f.lead,p_assign_unit_id:f.assign_unit_id});
    if(res.error){button.disabled=false;button.textContent=move?"Save Changes":"Create MOVE";return alert(res.error.message);}
    ctx.closeModal();
    await onSaved?.(move?move.id:res.data);
  };
}

/* ---------------- CSV ---------------- */

function csvEscape(value){return `"${String(value??"").replaceAll('"','""')}"`;}
function downloadCsv(filename,columns,rows){
  const body=[columns.map(c=>csvEscape(c.label)).join(","),...rows.map(row=>columns.map(c=>csvEscape(typeof c.value==="function"?c.value(row):row[c.value])).join(","))].join("\n");
  const href=URL.createObjectURL(new Blob([body],{type:"text/csv;charset=utf-8"}));
  const link=document.createElement("a");link.href=href;link.download=filename;link.click();
  setTimeout(()=>URL.revokeObjectURL(href),0);
}
function parseCsv(text){
  const rows=[];let row=[];let field="";let quoted=false;
  for(let i=0;i<text.length;i++){
    const ch=text[i];const next=text[i+1];
    if(quoted){
      if(ch==='"'&&next==='"'){field+='"';i++;}else if(ch==='"'){quoted=false;}else{field+=ch;}
      continue;
    }
    if(ch==='"')quoted=true;
    else if(ch===","){row.push(field);field="";}
    else if(ch==="\n"){row.push(field.replace(/\r$/,""));rows.push(row);row=[];field="";}
    else field+=ch;
  }
  row.push(field.replace(/\r$/,""));
  if(row.some(cell=>cell!==""))rows.push(row);
  return rows;
}
function normalizeHeader(value){return String(value||"").trim().toLowerCase().replace(/[^a-z0-9]+/g,"_").replace(/^_|_$/g,"");}
function mapCsvRows(text){
  const matrix=parseCsv(text);
  if(matrix.length<2)return {rows:[],errors:["CSV does not contain any data rows."]};
  const aliases={guest:"guest_name",name:"guest_name",passenger:"guest_name",passenger_name:"guest_name",guest_party:"guest_name",group:"guest_group",organization:"guest_group",party:"guest_group",count:"party_size",passengers:"party_size",pax:"party_size",scheduled:"scheduled_time",scheduled_at:"scheduled_time",pickup_time:"scheduled_time",time:"scheduled_time",type:"movement_type",pickup:"origin",pickup_location:"origin",from:"origin",dropoff:"destination",drop_off:"destination",dropoff_location:"destination",to:"destination",phone:"contact_phone",mobile:"contact_phone",email:"contact_email",flight:"flight_number",flight_no:"flight_number",carrier:"airline",airport_code:"airport"};
  const canonical=matrix[0].map(normalizeHeader).map(h=>aliases[h]||h);
  const missing=["guest_name","scheduled_time","origin","destination"].filter(f=>!canonical.includes(f));
  if(missing.length)return {rows:[],errors:[`Missing required column(s): ${missing.join(", ")}`]};
  const rows=[];const errors=[];
  matrix.slice(1).forEach((values,index)=>{
    if(values.every(v=>!String(v||"").trim()))return;
    const raw={};canonical.forEach((key,column)=>{raw[key]=String(values[column]??"").trim();});
    const line=index+2;
    const scheduledAt=parseLocalDateTime24(raw.scheduled_time);
    const partySize=raw.party_size?Number.parseInt(raw.party_size,10):1;
    const movementType=String(raw.movement_type||"OTHER").trim().toUpperCase().replace(/\s+/g,"_");
    if(!raw.guest_name)errors.push(`Row ${line}: guest_name is required.`);
    if(!scheduledAt)errors.push(`Row ${line}: scheduled_time must be YYYY-MM-DD HH:mm or an ISO timestamp.`);
    if(!raw.origin)errors.push(`Row ${line}: origin is required.`);
    if(!raw.destination)errors.push(`Row ${line}: destination is required.`);
    if(!MOVE_TYPES.includes(movementType))errors.push(`Row ${line}: movement_type is not recognized.`);
    rows.push({scheduled_at:scheduledAt,notes:raw.notes||null,guest:{movement_type:movementType,guest_name:raw.guest_name,guest_group:raw.guest_group||null,party_size:Number.isFinite(partySize)&&partySize>=1?partySize:1,origin:raw.origin,destination:raw.destination,airline:raw.airline||null,flight_number:raw.flight_number||null,airport:raw.airport||null,terminal:raw.terminal||null,contact_phone:raw.contact_phone||null,contact_email:raw.contact_email||null}});
  });
  return {rows,errors};
}

function importModal(ctx,{departmentId,onDone}){
  const departments=(ctx.departments||[]).filter(d=>d.active!==false&&d.guest_logistics_enabled===true);
  const content=ctx.openModal("move-import");
  content.__ccHtml=null;
  content.innerHTML=`<div class="incident-modal-header">
    <div><div class="incident-modal-eyebrow">GUEST LOGISTICS</div><h2 id="incidentModalTitle">Import MOVEs from CSV</h2>
    <div class="incident-modal-nature">Columns: guest_name, scheduled_time (YYYY-MM-DD HH:mm), origin, destination, optional movement_type, guest_group, party_size, airline, flight_number, airport, terminal, contact_phone, contact_email, notes</div></div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close">×</button></div>
    <div class="stack" style="padding:18px">
      <div class="grid2">
        <div><label>Department</label><select id="importDepartment">${departments.map(d=>`<option value="${d.id}" ${d.id===departmentId?"selected":""}>${esc(d.short_name||d.name)}</option>`).join("")}</select></div>
        <div><label>CSV file</label><input id="importFile" type="file" accept=".csv,text/csv"></div>
      </div>
      <div id="importPreview" class="small muted">Choose a file to preview.</div>
      <div class="grid2"><button class="btn" id="importRun" disabled>Import</button><button class="btn secondary" id="importTemplate">Download Template</button></div>
    </div>`;
  let parsed={rows:[],errors:[]};
  document.querySelector("#closeIncidentModal").onclick=()=>ctx.closeModal();
  document.querySelector("#importTemplate").onclick=()=>downloadCsv("guest-logistics-import-template.csv",
    ["guest_name","guest_group","party_size","scheduled_time","movement_type","origin","destination","airline","flight_number","airport","terminal","contact_phone","contact_email","notes"].map(k=>({label:k,value:k})),
    [{guest_name:"Example Guest",guest_group:"Delegation A",party_size:2,scheduled_time:"2026-10-21 14:30",movement_type:"AIRPORT_ARRIVAL",origin:"Airport Terminal B",destination:"Main Hotel",airline:"XX",flight_number:"XX123",airport:"XXX",terminal:"B",contact_phone:"",contact_email:"",notes:""}]);
  document.querySelector("#importFile").onchange=async e=>{
    const file=e.target.files?.[0];if(!file)return;
    parsed=mapCsvRows(await file.text());
    const preview=document.querySelector("#importPreview");
    preview.innerHTML=parsed.errors.length
      ?`<div class="notice error"><strong>${parsed.errors.length} problem(s):</strong><br>${parsed.errors.slice(0,12).map(esc).join("<br>")}${parsed.errors.length>12?"<br>…":""}</div>`
      :`<div class="notice ok">${parsed.rows.length} MOVE${parsed.rows.length===1?"":"S"} ready to import.</div>`;
    document.querySelector("#importRun").disabled=!!parsed.errors.length||!parsed.rows.length;
  };
  document.querySelector("#importRun").onclick=async()=>{
    const button=document.querySelector("#importRun");
    const deptId=document.querySelector("#importDepartment").value;
    button.disabled=true;
    let done=0;const failures=[];
    for(const row of parsed.rows){
      const {error}=await supabase.rpc("create_move_incident",{p_event_id:ctx.eventId,p_department_id:deptId,p_scheduled_at:row.scheduled_at,p_guest:row.guest,p_notes:row.notes});
      if(error)failures.push(`${row.guest.guest_name}: ${error.message}`);else done++;
      button.textContent=`Importing ${done+failures.length}/${parsed.rows.length}…`;
    }
    ctx.closeModal();
    if(failures.length)alert(`Imported ${done}. ${failures.length} failed:\n${failures.slice(0,8).join("\n")}`);
    await onDone?.();
  };
}

export function exportMovesCsv(ctx,moves){
  const unitName=id=>(ctx.units||[]).find(u=>u.id===id)?.name||"";
  const deptName=id=>{const d=(ctx.departments||[]).find(x=>x.id===id);return d?(d.short_name||d.name):"";};
  downloadCsv(`${(ctx.event?.event_code||"event").toLowerCase()}-guest-logistics.csv`,[
    {label:"move_number",value:"movement_number"},{label:"status",value:m=>movementStatusLabel(m.status)},{label:"department",value:m=>deptName(m.department_id)},
    {label:"scheduled",value:m=>dateTime24(m.scheduled_at)},{label:"movement_type",value:m=>movementTypeLabel(m.movement_type)},
    {label:"guest_name",value:"guest_name"},{label:"guest_group",value:"guest_group"},{label:"party_size",value:"party_size"},
    {label:"origin",value:"origin"},{label:"destination",value:"destination"},{label:"airline",value:"airline"},{label:"flight_number",value:"flight_number"},
    {label:"airport",value:"airport"},{label:"terminal",value:"terminal"},{label:"driver",value:m=>unitName(m.assigned_unit_id)},
    {label:"driver_acknowledged",value:m=>dateTime24(m.driver_acknowledged_at)},{label:"contact_phone",value:"contact_phone"},{label:"notes",value:"notes"}
  ],moves);
}

/* ---------------- Dispatch board ---------------- */

function moveCard(m,ctx){
  const unit=(ctx.units||[]).find(u=>u.id===m.assigned_unit_id);
  const department=(ctx.departments||[]).find(d=>d.id===m.department_id);
  const risk=movementRisk(m);
  const flight=[m.airline,m.flight_number].filter(Boolean).join(" ");
  return `<article class="logistics-movement-card ${risk?.level==="late"?"logistics-overdue":""} ${risk?.level==="risk"?"logistics-at-risk":""} ${m.incident_status==="SCHEDULED"?"logistics-scheduled":""}" data-move-open="${m.id}">
    <div class="logistics-movement-time"><strong>${esc(time24(m.scheduled_at))}</strong><span>${esc(new Date(m.scheduled_at).toLocaleDateString([],{month:"2-digit",day:"2-digit"}))}</span></div>
    <div class="logistics-movement-main">
      <div class="row start">
        <strong>${esc(m.movement_number)}</strong>
        <span class="badge ${movementStatusClass(m.status)}">${esc(movementStatusLabel(m.status))}</span>
        ${m.incident_status==="OPEN"?`<span class="badge">ACTIVE</span>`:""}
        ${m.driver_acknowledged_at?`<span class="badge logistics-ack-badge">ACK</span>`:""}
        ${risk?`<span class="badge risk-badge risk-${risk.level}">${esc(risk.label)}</span>`:""}
        ${m.link&&m.incident_status==="OPEN"?(m.is_primary?`<span class="badge queue-badge current">CURRENT</span>`:`<span class="badge queue-badge">QUEUED #${m.queue_position||"?"}</span>`):""}
      </div>
      <div class="logistics-guest-line">${esc(m.guest_name)}${m.guest_group?` · ${esc(m.guest_group)}`:""} · ${m.party_size} pax</div>
      <div class="small muted">${esc(movementTypeLabel(m.movement_type))}${flight?` · ${esc(flight)}`:""}${m.airport?` · ${esc(m.airport)}`:""}</div>
      <div class="logistics-route"><span>${esc(m.origin)}</span><strong>→</strong><span>${esc(m.destination)}</span></div>
      <div class="small">${department?`${esc(department.short_name||department.name)} · `:""}Driver: <strong>${esc(unit?.name||"Unassigned")}</strong></div>
    </div>
    <button class="btn secondary compact" data-move-open="${m.id}">Open Ticket</button>
  </article>`;
}

export async function renderGuestLogistics(app,ctx){
  const departments=(ctx.departments||[]).filter(d=>d.active!==false&&d.guest_logistics_enabled===true&&(ctx.dispatchDepartmentIds||[]).includes(d.id));
  if(!departments.length){
    app.innerHTML=`<div class="shell">${ctx.header(`${esc(ctx.event?.name||"Event")} · Guest Logistics`)}
      <div class="center"><div class="card stack"><h2>Guest Logistics is not enabled</h2>
      <p class="muted">Enable Guest Logistics on a department in Event Admin → Setup → Edit Department, or widen the Dispatch Scope.</p>
      <button class="btn secondary" id="backGuestLogistics">Back to Dispatch</button></div></div></div>`;
    document.querySelector("#backGuestLogistics").onclick=ctx.onBack;
    return;
  }
  const deptIds=new Set(departments.map(d=>d.id));
  const state={filter:"upcoming",dept:"",query:""};

  const render=()=>{
    const all=(ctx.movements()||[]).filter(m=>deptIds.has(m.department_id));
    const now=Date.now();
    const dayEnd=new Date();dayEnd.setHours(23,59,59,999);
    let rows=all.filter(m=>!state.dept||m.department_id===state.dept);
    if(state.filter==="active")rows=rows.filter(m=>m.incident_status==="OPEN");
    else if(state.filter==="today")rows=rows.filter(m=>new Date(m.scheduled_at).getTime()<=dayEnd.getTime());
    else if(state.filter==="unassigned")rows=rows.filter(m=>!m.assigned_unit_id);
    else if(state.filter==="risk")rows=rows.filter(m=>movementRisk(m,now));
    if(state.query){
      const q=state.query.toLowerCase();
      rows=rows.filter(m=>[m.movement_number,m.guest_name,m.guest_group,m.origin,m.destination,m.flight_number].filter(Boolean).join(" ").toLowerCase().includes(q));
    }
    rows.sort((a,b)=>new Date(a.scheduled_at)-new Date(b.scheduled_at));
    const counts={active:all.filter(m=>m.incident_status==="OPEN").length,unassigned:all.filter(m=>!m.assigned_unit_id).length,risk:all.filter(m=>movementRisk(m,now)).length};
    const host=document.querySelector("#moveBoard");
    if(host)host.innerHTML=rows.map(m=>moveCard(m,ctx)).join("")||`<div class="small muted">No MOVEs match this view.</div>`;
    document.querySelector("#moveCountActive").textContent=counts.active;
    document.querySelector("#moveCountUnassigned").textContent=counts.unassigned;
    document.querySelector("#moveCountRisk").textContent=counts.risk;
    document.querySelector("#moveCountAll").textContent=all.length;
    document.querySelectorAll("[data-move-filter]").forEach(b=>b.classList.toggle("active",b.dataset.moveFilter===state.filter));
  };

  app.innerHTML=`<div class="shell">${ctx.header(`${esc(ctx.event?.name||"Event")} · Guest Logistics`)}
    <div class="wrap stack logistics-page">
      <div class="row">
        <div><div class="section-title">Guest Logistics</div><strong>Scheduled and active MOVE tickets</strong><div class="small muted">A MOVE becomes an active ticket on the Dispatch board about an hour before pickup. Open a ticket to assign a driver, change status or close it.</div></div>
        <div class="row" style="gap:8px"><button class="btn" id="newMove">+ New MOVE</button><button class="btn secondary" id="importMoves">Import CSV</button><button class="btn secondary" id="exportMoves">Export</button><button class="btn secondary" id="backGuestLogistics">Back to Dispatch</button></div>
      </div>
      <div class="command-display-metrics logistics-metrics">
        <div><span>ACTIVE</span><strong id="moveCountActive">0</strong></div>
        <div><span>UNASSIGNED</span><strong id="moveCountUnassigned">0</strong></div>
        <div><span>AT RISK / LATE</span><strong id="moveCountRisk">0</strong></div>
        <div><span>TOTAL OPEN</span><strong id="moveCountAll">0</strong></div>
      </div>
      <div class="row logistics-toolbar">
        <div class="command-filter-row">
          ${[["upcoming","Upcoming"],["today","Today"],["active","Active"],["unassigned","Unassigned"],["risk","At Risk"]].map(([k,l])=>`<button class="command-filter-chip" data-move-filter="${k}">${l}</button>`).join("")}
        </div>
        <select id="moveDept"><option value="">All GL departments</option>${departments.map(d=>`<option value="${d.id}">${esc(d.short_name||d.name)}</option>`).join("")}</select>
        <input id="moveSearch" placeholder="Search guest, number, flight, location">
      </div>
      <div id="moveBoard" class="logistics-board"></div>
    </div></div>`;

  document.querySelector("#backGuestLogistics").onclick=ctx.onBack;
  document.querySelector("#newMove").onclick=()=>moveFormModal(ctx,{departmentId:state.dept||departments[0].id,onSaved:async()=>{await ctx.reload();render();}});
  document.querySelector("#importMoves").onclick=()=>importModal(ctx,{departmentId:state.dept||departments[0].id,onDone:async()=>{await ctx.reload();render();}});
  document.querySelector("#exportMoves").onclick=()=>exportMovesCsv(ctx,(ctx.movements()||[]).filter(m=>deptIds.has(m.department_id)));
  document.querySelectorAll("[data-move-filter]").forEach(b=>b.onclick=()=>{state.filter=b.dataset.moveFilter;render();});
  document.querySelector("#moveDept").onchange=e=>{state.dept=e.target.value;render();};
  document.querySelector("#moveSearch").oninput=e=>{state.query=e.target.value.trim();render();};
  document.querySelector("#moveBoard").addEventListener("click",e=>{
    const el=e.target.closest("[data-move-open]");
    if(el)ctx.onOpenIncident(el.dataset.moveOpen);
  });
  ctx.onLiveUpdate?.(render);
  render();
}

/* ---------------- Field Unit panel ---------------- */

export async function loadFieldLogisticsState(eventId,unitId){
  const {data,error}=await supabase.from("incident_units")
    .select("id,incident_id,unit_id,assigned_at,acknowledged_at,cleared_at,cad_status,cad_status_updated_at,is_primary,queue_position,primary_set_at,primary_acknowledged_at,incidents!inner(id,event_id,incident_number,incident_kind,call_type,priority,status,scheduled_at,activated_at,notes,landmark,incident_guest_details(*))")
    .eq("unit_id",unitId)
    .is("cleared_at",null)
    .eq("incidents.incident_kind","MOVE")
    .neq("incidents.status","CLOSED");
  if(error)throw error;
  const rows=(data||[]).map(link=>{
    const incident={...link.incidents,incident_units:[{...link,incidents:undefined}]};
    return moveFromIncident(incident);
  }).filter(Boolean).sort((a,b)=>{
    const cur=Number(!!b.is_primary&&b.incident_status==="OPEN")-Number(!!a.is_primary&&a.incident_status==="OPEN");
    if(cur)return cur;
    const ad=Number(b.incident_status==="OPEN")-Number(a.incident_status==="OPEN");
    if(ad)return ad;
    return (a.queue_position||999)-(b.queue_position||999)||(new Date(a.scheduled_at||0)-new Date(b.scheduled_at||0));
  });
  const underwayMovement=rows.find(m=>MOVE_UNDERWAY_STATUSES.has(m.status))||null;
  return {current:underwayMovement||rows[0]||null,underway:!!underwayMovement,underwayMovement,movements:rows,upcoming:rows};
}

function fieldMoveActions(move){
  return moveStatusActions(move).filter(([s])=>s!=="CANCELLED");
}

function fieldMovementTaskHtml(move,state,index){
  const flight=[move.airline,move.flight_number].filter(Boolean).join(" ");
  const isCurrent=!!move.is_primary&&move.incident_status==="OPEN";
  const underway=isCurrent&&MOVE_UNDERWAY_STATUSES.has(move.status);
  const queuedBehindOther=!isCurrent;
  const pendingAck=!move.driver_acknowledged_at;
  const actions=fieldMoveActions(move);
  const risk=movementRisk(move);
  const scheduledOnly=move.incident_status==="SCHEDULED";
  const currentTask=state?.currentTask||null;
  return `<section class="field-logistics-task ${underway?"field-logistics-task-underway":""} ${pendingAck?"field-move-card-pending":""}">
    ${pendingAck?`<div class="field-new-move" role="alert" aria-live="assertive">
      <div><div class="field-new-move-kicker">NEW MOVE ASSIGNMENT</div>
        <strong>${esc(move.movement_number)} · ${esc(move.guest_name)}</strong>
        <div class="small">${esc([move.origin,move.destination].filter(Boolean).join(" → "))} · Assigned ${move.assigned_at?esc(dateTime24(move.assigned_at)):"just now"}</div></div>
      <button class="btn field-move-acknowledge-button" data-field-logistics-ack="${move.id}">ACKNOWLEDGE MOVE</button>
    </div>`:`<div class="field-move-acknowledged"><span class="badge">ACKNOWLEDGED${move.driver_acknowledged_at?` · ${esc(time24(move.driver_acknowledged_at))}`:""}</span></div>`}
    <div class="row">
      <div>
        <div class="small task-priority-label ${isCurrent?"field-current-task-label":"field-queued-task-label"}">${isCurrent?"CURRENT TASK · MOVE":scheduledOnly?`SCHEDULED MOVE${move.queue_position?` · QUEUE #${move.queue_position}`:""}`:`QUEUED #${move.queue_position||"?"} · MOVE${currentTask&&currentTask.id!==move.id?` · current: ${esc(currentTask.number)}`:""}`}</div>
        <div class="row start"><strong class="big">${esc(move.movement_number)}</strong><span class="badge ${movementStatusClass(move.status)}">${esc(movementStatusLabel(move.status))}</span>${risk?`<span class="badge risk-badge risk-${risk.level}">${esc(risk.label)}</span>`:""}</div>
      </div>
      <div class="field-logistics-scheduled"><span>Scheduled</span><strong class="mono">${esc(dateTime24(move.scheduled_at))}</strong></div>
    </div>
    <div class="field-logistics-guest"><strong>${esc(move.guest_name)}</strong><span>${move.guest_group?`${esc(move.guest_group)} · `:""}${move.party_size} pax</span></div>
    <div class="field-logistics-route"><div><span>Pickup</span><strong>${esc(move.origin)}</strong></div><div class="logistics-route-arrow">→</div><div><span>Destination</span><strong>${esc(move.destination)}</strong></div></div>
    ${flight||move.airport||move.terminal?`<div class="small field-logistics-flight">${flight?`<strong>${esc(flight)}</strong>`:""}${move.airport?` · ${esc(move.airport)}`:""}${move.terminal?` · Terminal ${esc(move.terminal)}`:""}</div>`:""}
    ${move.contact_phone?`<a class="btn secondary compact field-logistics-contact" href="tel:${esc(move.contact_phone)}">Call Guest / Contact</a>`:""}
    ${move.notes?`<div class="notice">${esc(move.notes)}</div>`:""}
    ${queuedBehindOther&&!scheduledOnly?`<div class="notice"><strong>Queued${currentTask?` behind ${esc(currentTask.number)}`:""}.</strong><br>Status controls unlock when this MOVE becomes your current task.</div>`:""}
    ${pendingAck?`<div class="small field-move-status-locked">Acknowledge this MOVE before using its status controls.</div>`:`
      <div class="field-task-status-head"><div class="section-title">MOVE STATUS</div><span class="badge ${movementStatusClass(move.status)}">${esc(movementStatusLabel(move.status))}</span></div>
      ${scheduledOnly?`<div class="small muted">This MOVE activates automatically before pickup. Starting En Route early activates it now.</div>`:""}
      <div class="logistics-action-grid field-logistics-actions">
        ${queuedBehindOther?`<div class="small muted">Status controls become available when this MOVE is your current task.</div>`
          :actions.map(([status,label,kind])=>`<button class="btn ${kind==="danger"?"danger":"good"}" data-field-logistics-status="${status}" data-movement-id="${move.id}">${esc(label)}</button>`).join("")||`<div class="small muted">No MOVE status action is available.</div>`}
      </div>`}
  </section>`;
}

function fieldQueuedMovementHtml(move){
  const risk=movementRisk(move);
  const pendingAck=!move.driver_acknowledged_at;
  return `<div class="field-logistics-queue-row ${pendingAck?"field-move-card-pending":""}">
    <div class="field-logistics-queue-time"><strong class="mono">${esc(time24(move.scheduled_at))}</strong><span class="small">${esc(new Date(move.scheduled_at).toLocaleDateString([],{month:"2-digit",day:"2-digit"}))}</span></div>
    <div class="field-logistics-queue-main">
      <div class="row start"><strong>${esc(move.movement_number)}</strong><span class="badge ${movementStatusClass(move.status)}">${esc(movementStatusLabel(move.status))}</span>${risk?`<span class="badge risk-badge risk-${risk.level}">${esc(risk.label)}</span>`:""}</div>
      <div class="small">${esc(move.guest_name)}${move.guest_group?` · ${esc(move.guest_group)}`:""} · ${move.party_size} pax</div>
      <div class="small muted">${esc(move.origin)} → ${esc(move.destination)}</div>
    </div>
    ${pendingAck?`<button class="btn compact field-move-acknowledge-button" data-field-logistics-ack="${move.id}">ACK</button>`:""}
  </div>`;
}

export function fieldLogisticsPanelHtml(state){
  const movements=state?.movements||[];
  if(!movements.length)return "";
  const [primary,...queued]=movements;
  const currentIsMove=!!primary.is_primary&&primary.incident_status==="OPEN";
  return `<div class="card field-logistics-card field-logistics-stack-card ${currentIsMove?"":"field-logistics-secondary"}">
    <div class="row">
      <div><div class="section-title">${currentIsMove?"CURRENT TASK · GUEST LOGISTICS":"GUEST LOGISTICS · QUEUED"}</div><strong>${movements.length} assigned MOVE${movements.length===1?"":"S"}</strong></div>
      ${currentIsMove&&MOVE_UNDERWAY_STATUSES.has(primary.status)?`<span class="badge logistics-primary-badge">UNDERWAY</span>`:`<span class="badge">${currentIsMove?"CURRENT":"QUEUED"}</span>`}
    </div>
    <div class="field-logistics-task-stack">${fieldMovementTaskHtml(primary,state,0)}</div>
    ${queued.length?`<div class="field-logistics-queue"><div class="section-title">UPCOMING · ${queued.length} MORE</div>${queued.map(fieldQueuedMovementHtml).join("")}</div>`:""}
  </div>`;
}

export function bindFieldLogisticsPanel(state,{refresh,fieldSessionId,unitId}){
  const movements=state?.movements||[];
  if(!movements.length)return;
  const byId=new Map(movements.map(m=>[m.id,m]));
  document.querySelectorAll("[data-field-logistics-ack]").forEach(button=>{
    button.onclick=async()=>{
      const move=byId.get(button.dataset.fieldLogisticsAck);if(!move)return;
      button.disabled=true;const original=button.textContent;button.textContent="Acknowledging…";
      const {error}=await supabase.rpc("field_acknowledge_assignment",{p_field_session_id:fieldSessionId,p_incident_id:move.id});
      if(error){button.disabled=false;button.textContent=original;return alert(error.message);}
      await refresh();
    };
  });
  document.querySelectorAll("[data-field-logistics-status][data-movement-id]").forEach(button=>{
    button.onclick=async()=>{
      const move=byId.get(button.dataset.movementId);if(!move)return;
      const status=button.dataset.fieldLogisticsStatus;
      if(status==="NO_SHOW"&&!confirm("Confirm the guest / party is a No Show?"))return;
      button.disabled=true;const original=button.textContent;button.textContent="Updating…";
      try{await setMoveStatus(move.id,unitId,status);}
      catch(error){button.disabled=false;button.textContent=original;return alert(error.message);}
      await refresh();
    };
  });
}
