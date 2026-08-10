import { supabase } from "./supabase.js";

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({
  "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"
}[m]));

let staffingChannel=null;

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

function parseDateTime24(raw){
  const value=String(raw||"").trim();
  if(!value)return null;

  const match=value.match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/);
  if(!match)return null;

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

function personnelDisplayName(person){
  return person?.preferred_name||person?.full_name||"Personnel";
}

function staffingStatusLabel(status){
  return ({
    PLANNED:"Not Checked In",
    CHECKED_IN:"Checked In",
    CHECKED_OUT:"Checked Out",
    CANCELLED:"Cancelled"
  })[status]||String(status||"").replaceAll("_"," ");
}

function staffingStatusClass(status){
  return `staffing-status-${String(status||"").toLowerCase().replaceAll("_","-")}`;
}

function csvEscape(value){
  return `"${String(value??"").replaceAll('"','""')}"`;
}

function downloadCsv(filename,columns,rows){
  const content=[
    columns.map(c=>csvEscape(c.label)).join(","),
    ...rows.map(row=>columns.map(c=>csvEscape(
      typeof c.value==="function"?c.value(row):row[c.value]
    )).join(","))
  ].join("\n");

  const href=URL.createObjectURL(new Blob([content],{type:"text/csv;charset=utf-8"}));
  const link=document.createElement("a");
  link.href=href;
  link.download=filename;
  link.click();
  setTimeout(()=>URL.revokeObjectURL(href),0);
}

function visibleDepartments(ctx){
  const active=(ctx.departments||[]).filter(d=>d.active!==false);
  if(!Array.isArray(ctx.departmentIds)||!ctx.departmentIds.length)return active;
  const allowed=new Set(ctx.departmentIds);
  return active.filter(d=>allowed.has(d.id));
}

function visibleUnits(ctx){
  const departmentIds=new Set(visibleDepartments(ctx).map(d=>d.id));
  return (ctx.units||[]).filter(u=>u.active!==false&&departmentIds.has(u.department_id));
}

function activeOperationalPeriods(ctx){
  return (ctx.operationalPeriods||[])
    .filter(op=>op.status!=="CANCELLED")
    .sort((a,b)=>{
      const at=a.starts_at?new Date(a.starts_at).getTime():0;
      const bt=b.starts_at?new Date(b.starts_at).getTime():0;
      return at-bt||String(a.name).localeCompare(String(b.name));
    });
}

function selectedPeriodStorageKey(eventId){
  return `commcenter.staffing.operationalPeriod.${eventId}`;
}

function chooseInitialOperationalPeriod(ctx){
  const periods=activeOperationalPeriods(ctx);
  if(!periods.length)return null;

  let saved="";
  try{saved=localStorage.getItem(selectedPeriodStorageKey(ctx.eventId))||"";}catch{}

  return periods.find(op=>op.id===saved)
    ||periods.find(op=>op.status==="ACTIVE")
    ||periods.find(op=>op.status==="PLANNED")
    ||periods[periods.length-1];
}

function saveSelectedOperationalPeriod(eventId,opId){
  try{localStorage.setItem(selectedPeriodStorageKey(eventId),opId);}catch{}
}

async function fetchStaffingData(eventId){
  const [peopleRes,assignmentsRes]=await Promise.all([
    supabase.from("event_personnel")
      .select("*")
      .eq("event_id",eventId)
      .order("full_name"),
    supabase.from("unit_staffing_assignments")
      .select("*")
      .eq("event_id",eventId)
      .order("created_at")
  ]);

  if(peopleRes.error)throw peopleRes.error;
  if(assignmentsRes.error)throw assignmentsRes.error;

  return {
    people:peopleRes.data||[],
    assignments:assignmentsRes.data||[]
  };
}

function ensureModal(){
  let modal=document.querySelector("#unitStaffingModal");
  if(modal)return modal;

  document.body.insertAdjacentHTML("beforeend",`
    <div class="staffing-modal-backdrop" id="unitStaffingModal" aria-hidden="true">
      <div class="staffing-modal" role="dialog" aria-modal="true">
        <div id="unitStaffingModalContent"></div>
      </div>
    </div>
  `);

  modal=document.querySelector("#unitStaffingModal");
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
  return document.querySelector("#unitStaffingModalContent");
}

function closeModal(){
  const modal=document.querySelector("#unitStaffingModal");
  if(modal){
    modal.classList.remove("open");
    modal.setAttribute("aria-hidden","true");
  }
  document.body.classList.remove("modal-open");
}

function assignmentPerson(assignment,state){
  return state.people.find(p=>p.id===assignment.personnel_id)||null;
}

function assignmentUnit(assignment,ctx){
  return (ctx.units||[]).find(u=>u.id===assignment.unit_id)||null;
}

function assignmentDepartment(assignment,state,ctx){
  const person=assignmentPerson(assignment,state);
  return (ctx.departments||[]).find(d=>d.id===person?.department_id)||null;
}

function assignmentTimes(assignment){
  if(!assignment.planned_start_at&&!assignment.planned_end_at)return "";
  if(assignment.planned_start_at&&assignment.planned_end_at){
    return `${time24(assignment.planned_start_at)}–${time24(assignment.planned_end_at)}`;
  }
  if(assignment.planned_start_at)return `Starts ${time24(assignment.planned_start_at)}`;
  return `Until ${time24(assignment.planned_end_at)}`;
}

function assignmentRowHtml(assignment,state,ctx){
  const person=assignmentPerson(assignment,state);
  if(!person)return "";

  const identifier=person.personnel_identifier?` · ${esc(person.personnel_identifier)}`:"";
  const checkedTime=assignment.status==="CHECKED_IN"
    ?`Checked in ${esc(time24(assignment.checked_in_at))}`
    :assignment.status==="CHECKED_OUT"
      ?`Checked out ${esc(time24(assignment.checked_out_at))}`
      :"";

  return `<div class="staffing-person-row ${assignment.status==="CHECKED_IN"?"checked-in":""}" data-staffing-assignment="${assignment.id}">
    <div class="staffing-person-main">
      <div class="row start">
        <strong>${esc(personnelDisplayName(person))}</strong>
        <span class="badge ${staffingStatusClass(assignment.status)}">${esc(staffingStatusLabel(assignment.status))}</span>
      </div>
      <div class="small muted">${esc(person.full_name)}${identifier}</div>
      <div class="small staffing-role-line">
        ${assignment.role_label?`<strong>${esc(assignment.role_label)}</strong>`:""}
        ${assignmentTimes(assignment)?`${assignment.role_label?" · ":""}${esc(assignmentTimes(assignment))}`:""}
      </div>
      ${checkedTime?`<div class="small staffing-check-time">${checkedTime}</div>`:""}
    </div>

    <div class="staffing-person-actions">
      ${state.operationalPeriod?.status==="COMPLETE"
        ?`<span class="small muted">Historical</span>`
        :assignment.status==="CHECKED_IN"
          ?`<button class="btn secondary compact" data-staffing-checkout="${assignment.id}">Check Out</button>`
          :assignment.status!=="CANCELLED"
            ?`<button class="btn good compact" data-staffing-checkin="${assignment.id}">Check In</button>`
            :""}
      ${state.operationalPeriod?.status==="COMPLETE"?"":`<button class="btn secondary compact" data-staffing-edit-assignment="${assignment.id}">Edit</button>`}
    </div>
  </div>`;
}

function unitCardHtml(unit,assignments,state,ctx){
  const department=(ctx.departments||[]).find(d=>d.id===unit.department_id);
  const checked=assignments.filter(a=>a.status==="CHECKED_IN").length;
  const expected=assignments.filter(a=>a.status!=="CANCELLED").length;
  const complete=expected>0&&checked===expected;
  const partial=checked>0&&checked<expected;

  return `<article class="staffing-unit-card ${complete?"fully-checked-in":partial?"partially-checked-in":""}">
    <div class="staffing-unit-header">
      <div>
        <div class="small muted">${esc(department?.short_name||department?.name||"")}</div>
        <h3>${esc(unit.name)}</h3>
      </div>
      <div class="staffing-unit-count ${complete?"complete":""}">
        <strong>${checked}/${expected}</strong>
        <span>Checked In</span>
      </div>
    </div>

    <div class="staffing-unit-crew">
      ${assignments.filter(a=>a.status!=="CANCELLED").map(a=>assignmentRowHtml(a,state,ctx)).join("")
        ||`<div class="staffing-empty-unit">No personnel assigned for this Operational Period.</div>`}
    </div>

    ${state.operationalPeriod?.status==="COMPLETE"?"":`
      <div class="staffing-unit-footer">
        <button class="btn secondary compact" data-staffing-add-unit="${unit.id}">+ Assign Personnel</button>
        ${assignments.some(a=>a.status!=="CHECKED_IN"&&a.status!=="CANCELLED")
          ?`<button class="btn secondary compact" data-staffing-checkin-crew="${unit.id}">Check In Crew</button>`
          :""}
        ${assignments.some(a=>a.status==="CHECKED_IN")
          ?`<button class="btn secondary compact" data-staffing-checkout-crew="${unit.id}">Check Out Crew</button>`
          :""}
      </div>
    `}
  </article>`;
}

function unassignedAssignmentCard(assignments,state,ctx){
  if(!assignments.length)return "";

  const checked=assignments.filter(a=>a.status==="CHECKED_IN").length;
  const expected=assignments.filter(a=>a.status!=="CANCELLED").length;

  return `<article class="staffing-unit-card staffing-pool-card">
    <div class="staffing-unit-header">
      <div>
        <div class="small muted">RESERVE / STAGING</div>
        <h3>Unassigned Personnel Pool</h3>
      </div>
      <div class="staffing-unit-count">
        <strong>${checked}/${expected}</strong>
        <span>Checked In</span>
      </div>
    </div>

    <div class="staffing-unit-crew">
      ${assignments.filter(a=>a.status!=="CANCELLED").map(a=>assignmentRowHtml(a,state,ctx)).join("")}
    </div>

    ${state.operationalPeriod?.status==="COMPLETE"?"":`
      <div class="staffing-unit-footer">
        <button class="btn secondary compact" data-staffing-add-unit="">+ Add to Pool</button>
      </div>
    `}
  </article>`;
}

function personnelRosterRow(person,ctx){
  const dep=(ctx.departments||[]).find(d=>d.id===person.department_id);
  return `<div class="staffing-roster-row">
    <div>
      <strong>${esc(personnelDisplayName(person))}</strong>
      <div class="small muted">
        ${esc(person.full_name)}
        ${person.personnel_identifier?` · ${esc(person.personnel_identifier)}`:""}
        ${dep?` · ${esc(dep.name)}`:""}
      </div>
      ${(person.phone||person.email)?`<div class="small">${person.phone?esc(person.phone):""}${person.phone&&person.email?" · ":""}${person.email?esc(person.email):""}</div>`:""}
    </div>
    <div class="nav">
      <button class="btn secondary compact" data-staffing-edit-person="${person.id}">Edit</button>
      <button class="btn danger compact" data-staffing-archive-person="${person.id}">Archive</button>
    </div>
  </div>`;
}

async function personnelModal(ctx,state,person=null){
  const content=openModal();
  const departments=visibleDepartments(ctx);

  content.innerHTML=`<div class="staffing-modal-header">
    <div>
      <div class="section-title">UNIT STAFFING</div>
      <h2>${person?"Edit Personnel":"Add Personnel"}</h2>
    </div>
    <button class="staffing-modal-close" id="closeStaffingModal">×</button>
  </div>

  <div class="staffing-modal-body stack">
    <div class="grid2">
      <div>
        <label>Full Name</label>
        <input id="staffingFullName" value="${esc(person?.full_name||"")}" placeholder="First Last">
      </div>
      <div>
        <label>Preferred / Display Name</label>
        <input id="staffingPreferredName" value="${esc(person?.preferred_name||"")}" placeholder="Optional">
      </div>
      <div>
        <label>Department</label>
        <select id="staffingPersonnelDepartment">
          ${departments.map(dep=>`<option value="${dep.id}" ${dep.id===person?.department_id?"selected":""}>${esc(dep.name)}</option>`).join("")}
        </select>
      </div>
      <div>
        <label>Personnel ID / Badge #</label>
        <input id="staffingPersonnelIdentifier" value="${esc(person?.personnel_identifier||"")}" placeholder="Optional">
      </div>
      <div>
        <label>Phone</label>
        <input id="staffingPersonnelPhone" value="${esc(person?.phone||"")}" placeholder="Optional">
      </div>
      <div>
        <label>Email</label>
        <input id="staffingPersonnelEmail" value="${esc(person?.email||"")}" placeholder="Optional">
      </div>
    </div>

    <div>
      <label>Notes</label>
      <textarea id="staffingPersonnelNotes" rows="3">${esc(person?.notes||"")}</textarea>
    </div>

    <div id="staffingPersonnelError" class="small destructive-error"></div>
  </div>

  <div class="staffing-modal-footer">
    <button class="btn secondary" id="cancelStaffingPersonnel">Cancel</button>
    <button class="btn" id="saveStaffingPersonnel">${person?"Save Personnel":"Add Personnel"}</button>
  </div>`;

  const close=closeModal;
  document.querySelector("#closeStaffingModal").onclick=close;
  document.querySelector("#cancelStaffingPersonnel").onclick=close;

  document.querySelector("#saveStaffingPersonnel").onclick=async()=>{
    const fullName=document.querySelector("#staffingFullName").value.trim();
    const errorHost=document.querySelector("#staffingPersonnelError");
    if(!fullName){
      errorHost.textContent="Full Name is required.";
      return;
    }

    const button=document.querySelector("#saveStaffingPersonnel");
    button.disabled=true;
    button.textContent="Saving…";

    const args={
      p_department_id:document.querySelector("#staffingPersonnelDepartment").value,
      p_full_name:fullName,
      p_preferred_name:document.querySelector("#staffingPreferredName").value.trim()||null,
      p_personnel_identifier:document.querySelector("#staffingPersonnelIdentifier").value.trim()||null,
      p_phone:document.querySelector("#staffingPersonnelPhone").value.trim()||null,
      p_email:document.querySelector("#staffingPersonnelEmail").value.trim()||null,
      p_notes:document.querySelector("#staffingPersonnelNotes").value.trim()||null
    };

    const result=person
      ?await supabase.rpc("staffing_update_personnel",{
          p_personnel_id:person.id,
          ...args
        })
      :await supabase.rpc("staffing_create_personnel",{
          p_event_id:ctx.eventId,
          ...args
        });

    if(result.error){
      button.disabled=false;
      button.textContent=person?"Save Personnel":"Add Personnel";
      errorHost.textContent=result.error.message;
      return;
    }

    closeModal();
    await state.reload();
  };
}

async function quickAddPersonnelModal(ctx,state){
  const content=openModal();
  const departments=visibleDepartments(ctx);

  content.innerHTML=`<div class="staffing-modal-header">
    <div>
      <div class="section-title">UNIT STAFFING</div>
      <h2>Quick Add Names</h2>
    </div>
    <button class="staffing-modal-close" id="closeStaffingModal">×</button>
  </div>

  <div class="staffing-modal-body stack">
    <div>
      <label>Department</label>
      <select id="staffingQuickDepartment">
        ${departments.map(dep=>`<option value="${dep.id}">${esc(dep.name)}</option>`).join("")}
      </select>
    </div>

    <div>
      <label>Names — one person per line</label>
      <textarea id="staffingQuickNames" rows="12" placeholder="Jane Smith&#10;John Doe&#10;Alex Johnson"></textarea>
      <div class="small muted">These names are added to the event personnel roster. You can add badge numbers, phone numbers, and other details later from Personnel Roster.</div>
    </div>

    <div id="staffingQuickError" class="small destructive-error"></div>
  </div>

  <div class="staffing-modal-footer">
    <button class="btn secondary" id="cancelStaffingQuick">Cancel</button>
    <button class="btn" id="saveStaffingQuick">Add Names</button>
  </div>`;

  document.querySelector("#closeStaffingModal").onclick=closeModal;
  document.querySelector("#cancelStaffingQuick").onclick=closeModal;

  document.querySelector("#saveStaffingQuick").onclick=async()=>{
    const names=document.querySelector("#staffingQuickNames").value
      .split(/\r?\n/)
      .map(name=>name.trim())
      .filter(Boolean);

    const errorHost=document.querySelector("#staffingQuickError");
    if(!names.length){
      errorHost.textContent="Enter at least one name.";
      return;
    }

    const departmentId=document.querySelector("#staffingQuickDepartment").value;
    const button=document.querySelector("#saveStaffingQuick");
    button.disabled=true;
    button.textContent=`Adding ${names.length}…`;

    const errors=[];
    for(const name of names){
      const {error}=await supabase.rpc("staffing_create_personnel",{
        p_event_id:ctx.eventId,
        p_department_id:departmentId,
        p_full_name:name,
        p_preferred_name:null,
        p_personnel_identifier:null,
        p_phone:null,
        p_email:null,
        p_notes:null
      });
      if(error)errors.push(`${name}: ${error.message}`);
    }

    if(errors.length){
      button.disabled=false;
      button.textContent="Add Names";
      errorHost.textContent=errors.join(" ");
      await state.reload();
      return;
    }

    closeModal();
    await state.reload();
  };
}

async function rosterModal(ctx,state){
  const content=openModal();
  const departments=visibleDepartments(ctx);
  const allowed=new Set(departments.map(d=>d.id));
  const people=state.people.filter(p=>p.active!==false&&allowed.has(p.department_id));

  content.innerHTML=`<div class="staffing-modal-header">
    <div>
      <div class="section-title">UNIT STAFFING</div>
      <h2>Personnel Roster</h2>
      <div class="small muted">${people.length} active personnel</div>
    </div>
    <button class="staffing-modal-close" id="closeStaffingModal">×</button>
  </div>

  <div class="staffing-modal-body stack">
    <div class="row">
      <input id="staffingRosterSearch" placeholder="Search name, department, badge, phone…" style="flex:1">
      <button class="btn" id="rosterAddPerson">+ Add Personnel</button>
      <button class="btn secondary" id="rosterQuickAdd">Quick Add Names</button>
    </div>

    <div id="staffingRosterList" class="staffing-roster-list">
      ${people.map(person=>personnelRosterRow(person,ctx)).join("")||`<div class="notice">No personnel have been added yet.</div>`}
    </div>
  </div>

  <div class="staffing-modal-footer">
    <button class="btn secondary" id="closeRoster">Close</button>
  </div>`;

  const bindRows=()=>{
    document.querySelectorAll("[data-staffing-edit-person]").forEach(button=>{
      button.onclick=()=>personnelModal(ctx,state,state.people.find(p=>p.id===button.dataset.staffingEditPerson));
    });

    document.querySelectorAll("[data-staffing-archive-person]").forEach(button=>{
      button.onclick=async()=>{
        const person=state.people.find(p=>p.id===button.dataset.staffingArchivePerson);
        if(!person)return;

        const typed=prompt(`Type the person's full name exactly to archive this personnel record:\n\n${person.full_name}`);
        if(typed===null)return;

        const {error}=await supabase.rpc("staffing_archive_personnel",{
          p_personnel_id:person.id,
          p_confirmation:typed
        });

        if(error)return alert(error.message);

        closeModal();
        await state.reload();
        rosterModal(ctx,state);
      };
    });
  };

  document.querySelector("#closeStaffingModal").onclick=closeModal;
  document.querySelector("#closeRoster").onclick=closeModal;
  document.querySelector("#rosterAddPerson").onclick=()=>personnelModal(ctx,state);
  document.querySelector("#rosterQuickAdd").onclick=()=>quickAddPersonnelModal(ctx,state);

  document.querySelector("#staffingRosterSearch").oninput=event=>{
    const q=event.target.value.trim().toLowerCase();
    const filtered=people.filter(person=>{
      const dep=(ctx.departments||[]).find(d=>d.id===person.department_id);
      return [
        person.full_name,
        person.preferred_name,
        person.personnel_identifier,
        person.phone,
        person.email,
        dep?.name,
        dep?.short_name
      ].filter(Boolean).join(" ").toLowerCase().includes(q);
    });

    document.querySelector("#staffingRosterList").innerHTML=
      filtered.map(person=>personnelRosterRow(person,ctx)).join("")
      ||`<div class="notice">No personnel match that search.</div>`;
    bindRows();
  };

  bindRows();
}

function availablePeopleForAssignment(ctx,state,opId,currentPersonnelId=null){
  const allowedDepartments=new Set(visibleDepartments(ctx).map(d=>d.id));
  const alreadyAssigned=new Set(
    state.assignments
      .filter(a=>a.operational_period_id===opId&&a.status!=="CANCELLED"&&a.personnel_id!==currentPersonnelId)
      .map(a=>a.personnel_id)
  );

  return state.people
    .filter(p=>p.active!==false&&allowedDepartments.has(p.department_id)&&!alreadyAssigned.has(p.id))
    .sort((a,b)=>personnelDisplayName(a).localeCompare(personnelDisplayName(b)));
}

async function assignmentModal(ctx,state,{
  assignment=null,
  personnelId=null,
  unitId=null
}={}){
  const content=openModal();
  const op=state.operationalPeriod;
  if(!op)return;

  const people=availablePeopleForAssignment(ctx,state,op.id,assignment?.personnel_id);
  const person=assignment
    ?state.people.find(p=>p.id===assignment.personnel_id)
    :state.people.find(p=>p.id===personnelId);

  if(person&&!people.some(p=>p.id===person.id))people.unshift(person);

  const units=visibleUnits(ctx);
  const selectedUnit=assignment?.unit_id??unitId??"";

  content.innerHTML=`<div class="staffing-modal-header">
    <div>
      <div class="section-title">UNIT STAFFING · ${esc(op.name)}</div>
      <h2>${assignment?"Edit Staffing Assignment":"Assign Personnel"}</h2>
    </div>
    <button class="staffing-modal-close" id="closeStaffingModal">×</button>
  </div>

  <div class="staffing-modal-body stack">
    <div class="notice staffing-op-notice">
      <strong>${esc(op.name)}</strong>
      ${op.starts_at||op.ends_at?`<br>${esc(dateTime24(op.starts_at))} → ${esc(dateTime24(op.ends_at))}`:""}
      <br><span class="small">This assignment exists only for this Operational Period.</span>
    </div>

    <div class="grid2">
      <div>
        <label>Personnel</label>
        <select id="staffingAssignmentPerson" ${assignment||personnelId?"disabled":""}>
          <option value="">Choose personnel…</option>
          ${people.map(p=>`<option value="${p.id}" ${p.id===(assignment?.personnel_id||personnelId)?"selected":""}>${esc(personnelDisplayName(p))} · ${esc((ctx.departments||[]).find(d=>d.id===p.department_id)?.short_name||"")}</option>`).join("")}
        </select>
      </div>

      <div>
        <label>Unit / Assignment</label>
        <select id="staffingAssignmentUnit">
          <option value="">Unassigned / Reserve Pool</option>
          ${units.map(unit=>`<option value="${unit.id}" ${unit.id===selectedUnit?"selected":""}>${esc(unit.name)} · ${esc((ctx.departments||[]).find(d=>d.id===unit.department_id)?.short_name||"")}</option>`).join("")}
        </select>
      </div>

      <div>
        <label>Role / Position</label>
        <input id="staffingAssignmentRole" value="${esc(assignment?.role_label||"")}" placeholder="Medic, Driver, Team Lead, Officer…">
      </div>

      <div></div>

      <div>
        <label>Planned Start (24-hour)</label>
        <input id="staffingAssignmentStart" inputmode="numeric" value="${esc(dateInputValue(assignment?.planned_start_at||op.starts_at))}" placeholder="YYYY-MM-DD HH:mm">
      </div>

      <div>
        <label>Planned End (24-hour)</label>
        <input id="staffingAssignmentEnd" inputmode="numeric" value="${esc(dateInputValue(assignment?.planned_end_at||op.ends_at))}" placeholder="YYYY-MM-DD HH:mm">
      </div>
    </div>

    <div>
      <label>Assignment Notes</label>
      <textarea id="staffingAssignmentNotes" rows="3">${esc(assignment?.notes||"")}</textarea>
    </div>

    <div id="staffingAssignmentError" class="small destructive-error"></div>
  </div>

  <div class="staffing-modal-footer">
    ${assignment&&assignment.status!=="CANCELLED"?`<button class="btn danger" id="cancelStaffingAssignment">Cancel Assignment</button>`:""}
    <button class="btn secondary" id="cancelStaffingAssignmentEdit">Close</button>
    <button class="btn" id="saveStaffingAssignment">Save Assignment</button>
  </div>`;

  document.querySelector("#closeStaffingModal").onclick=closeModal;
  document.querySelector("#cancelStaffingAssignmentEdit").onclick=closeModal;

  document.querySelector("#saveStaffingAssignment").onclick=async()=>{
    const selectedPersonId=assignment?.personnel_id||personnelId||document.querySelector("#staffingAssignmentPerson").value;
    const startRaw=document.querySelector("#staffingAssignmentStart").value.trim();
    const endRaw=document.querySelector("#staffingAssignmentEnd").value.trim();
    const startAt=startRaw?parseDateTime24(startRaw):null;
    const endAt=endRaw?parseDateTime24(endRaw):null;
    const errorHost=document.querySelector("#staffingAssignmentError");

    if(!selectedPersonId){
      errorHost.textContent="Choose personnel.";
      return;
    }
    if(startRaw&&!startAt){
      errorHost.textContent="Planned Start must use YYYY-MM-DD HH:mm.";
      return;
    }
    if(endRaw&&!endAt){
      errorHost.textContent="Planned End must use YYYY-MM-DD HH:mm.";
      return;
    }
    if(startAt&&endAt&&new Date(endAt)<=new Date(startAt)){
      errorHost.textContent="Planned End must be after Planned Start.";
      return;
    }

    const button=document.querySelector("#saveStaffingAssignment");
    button.disabled=true;
    button.textContent="Saving…";

    const {error}=await supabase.rpc("staffing_save_assignment",{
      p_personnel_id:selectedPersonId,
      p_operational_period_id:op.id,
      p_unit_id:document.querySelector("#staffingAssignmentUnit").value||null,
      p_role_label:document.querySelector("#staffingAssignmentRole").value.trim()||null,
      p_planned_start_at:startAt,
      p_planned_end_at:endAt,
      p_notes:document.querySelector("#staffingAssignmentNotes").value.trim()||null
    });

    if(error){
      button.disabled=false;
      button.textContent="Save Assignment";
      errorHost.textContent=error.message;
      return;
    }

    closeModal();
    await state.reload();
  };

  document.querySelector("#cancelStaffingAssignment")?.addEventListener("click",async()=>{
    if(!confirm(`Cancel ${personnelDisplayName(person)}'s assignment for ${op.name}?`))return;

    const {error}=await supabase.rpc("staffing_cancel_assignment",{
      p_assignment_id:assignment.id
    });

    if(error)return alert(error.message);

    closeModal();
    await state.reload();
  });
}

async function copyPeriodModal(ctx,state){
  const content=openModal();
  const target=state.operationalPeriod;
  const sourcePeriods=activeOperationalPeriods(ctx).filter(op=>op.id!==target?.id);

  content.innerHTML=`<div class="staffing-modal-header">
    <div>
      <div class="section-title">UNIT STAFFING</div>
      <h2>Copy Staffing to ${esc(target?.name||"Operational Period")}</h2>
    </div>
    <button class="staffing-modal-close" id="closeStaffingModal">×</button>
  </div>

  <div class="staffing-modal-body stack">
    <div class="notice">
      Copy unit assignments from another Operational Period. Existing personnel assignments in <strong>${esc(target?.name||"")}</strong> are not overwritten.
    </div>

    <div>
      <label>Copy From</label>
      <select id="staffingCopySource">
        <option value="">Choose Operational Period…</option>
        ${sourcePeriods.map(op=>`<option value="${op.id}">${esc(op.name)} · ${esc(op.incident_prefix||"")}</option>`).join("")}
      </select>
    </div>

    <div class="small muted">
      Personnel, unit, role, and notes are copied. Planned start/end are reset to the target Operational Period's planned times. Everyone starts as Not Checked In.
    </div>

    <div id="staffingCopyError" class="small destructive-error"></div>
  </div>

  <div class="staffing-modal-footer">
    <button class="btn secondary" id="cancelStaffingCopy">Cancel</button>
    <button class="btn" id="confirmStaffingCopy">Copy Assignments</button>
  </div>`;

  document.querySelector("#closeStaffingModal").onclick=closeModal;
  document.querySelector("#cancelStaffingCopy").onclick=closeModal;

  document.querySelector("#confirmStaffingCopy").onclick=async()=>{
    const sourceId=document.querySelector("#staffingCopySource").value;
    if(!sourceId){
      document.querySelector("#staffingCopyError").textContent="Choose an Operational Period to copy.";
      return;
    }

    if(!confirm(`Copy staffing assignments into ${target.name}? Existing assignments will be preserved.`))return;

    const button=document.querySelector("#confirmStaffingCopy");
    button.disabled=true;
    button.textContent="Copying…";

    const {data,error}=await supabase.rpc("staffing_copy_operational_period",{
      p_source_operational_period_id:sourceId,
      p_target_operational_period_id:target.id
    });

    if(error){
      button.disabled=false;
      button.textContent="Copy Assignments";
      document.querySelector("#staffingCopyError").textContent=error.message;
      return;
    }

    closeModal();
    await state.reload();
    alert(`Copied ${data} staffing assignment${Number(data)===1?"":"s"} into ${target.name}.`);
  };
}

async function checkAssignment(assignmentId,checkIn,state){
  const {error}=await supabase.rpc(
    checkIn?"staffing_check_in":"staffing_check_out",
    {p_assignment_id:assignmentId}
  );

  if(error)throw error;
  await state.reload();
}

async function checkCrew(unitId,checkIn,state){
  const assignments=state.periodAssignments.filter(a=>
    (a.unit_id||"")===(unitId||"")
    &&a.status!=="CANCELLED"
    &&(checkIn?a.status!=="CHECKED_IN":a.status==="CHECKED_IN")
  );

  if(!assignments.length)return;

  const action=checkIn?"check in":"check out";
  if(!confirm(`${checkIn?"Check in":"Check out"} ${assignments.length} crew member${assignments.length===1?"":"s"} on this assignment?`))return;

  const errors=[];
  for(const assignment of assignments){
    const {error}=await supabase.rpc(
      checkIn?"staffing_check_in":"staffing_check_out",
      {p_assignment_id:assignment.id}
    );
    if(error)errors.push(error.message);
  }

  await state.reload();
  if(errors.length)alert(`Some personnel could not ${action}: ${errors.join(" ")}`);
}

function exportRows(state,ctx){
  return state.periodAssignments
    .filter(a=>a.status!=="CANCELLED")
    .map(assignment=>{
      const person=assignmentPerson(assignment,state);
      const unit=assignmentUnit(assignment,ctx);
      const dep=assignmentDepartment(assignment,state,ctx);
      return {assignment,person,unit,dep};
    });
}

function boardHtml(ctx,state){
  const op=state.operationalPeriod;
  const departments=visibleDepartments(ctx);
  const units=visibleUnits(ctx);
  const allowedDepartmentIds=new Set(departments.map(d=>d.id));

  state.periodAssignments=state.assignments.filter(a=>a.operational_period_id===op.id);
  const activeAssignments=state.periodAssignments.filter(a=>a.status!=="CANCELLED");
  const assignedPersonnelIds=new Set(activeAssignments.map(a=>a.personnel_id));
  const visiblePeople=state.people.filter(p=>p.active!==false&&allowedDepartmentIds.has(p.department_id));
  const notScheduled=visiblePeople.filter(p=>!assignedPersonnelIds.has(p.id));

  const checkedIn=activeAssignments.filter(a=>a.status==="CHECKED_IN").length;
  const expected=activeAssignments.length;
  const unitAssigned=activeAssignments.filter(a=>a.unit_id).length;
  const poolAssignments=activeAssignments.filter(a=>!a.unit_id);

  const departmentSections=departments.map(dep=>{
    const departmentUnits=units.filter(u=>u.department_id===dep.id);
    const cards=departmentUnits.map(unit=>
      unitCardHtml(
        unit,
        activeAssignments.filter(a=>a.unit_id===unit.id),
        state,
        ctx
      )
    ).join("");

    const depNotScheduled=notScheduled.filter(p=>p.department_id===dep.id);

    return `<section class="staffing-department-section">
      <div class="staffing-department-heading">
        <div>
          <div class="section-title">DEPARTMENT</div>
          <h2>${esc(dep.name)}</h2>
        </div>
        <div class="staffing-department-summary">
          ${activeAssignments.filter(a=>assignmentPerson(a,state)?.department_id===dep.id&&a.status==="CHECKED_IN").length}
          checked in ·
          ${activeAssignments.filter(a=>assignmentPerson(a,state)?.department_id===dep.id).length}
          scheduled
        </div>
      </div>

      <div class="staffing-unit-grid">
        ${cards||`<div class="card"><div class="muted">No active units in this department.</div></div>`}
      </div>

      ${depNotScheduled.length?`
        <div class="staffing-not-scheduled">
          <div class="section-title">NOT SCHEDULED THIS OPERATIONAL PERIOD</div>
          <div class="staffing-unscheduled-grid">
            ${depNotScheduled.map(person=>state.operationalPeriod?.status==="COMPLETE"
              ?`<div class="choice staffing-unscheduled-person">
                  <strong>${esc(personnelDisplayName(person))}</strong>
                  <span>${esc(person.full_name)}</span>
                  ${person.personnel_identifier?`<small>${esc(person.personnel_identifier)}</small>`:""}
                </div>`
              :`<button class="choice staffing-unscheduled-person" data-staffing-assign-person="${person.id}">
                  <strong>${esc(personnelDisplayName(person))}</strong>
                  <span>${esc(person.full_name)}</span>
                  ${person.personnel_identifier?`<small>${esc(person.personnel_identifier)}</small>`:""}
                </button>`
            ).join("")}
          </div>
        </div>
      `:""}
    </section>`;
  }).join("");

  return `<div class="staffing-command-shell" id="staffingCommandShell">
    <header class="staffing-command-header">
      <div>
        <div class="command-display-brand">CommCenter Pro</div>
        <div class="staffing-command-event">${esc(ctx.event?.name||"Event")} · Unit Staffing</div>
      </div>

      <div class="staffing-command-metrics">
        <div><span>OPERATIONAL PERIOD</span><strong>${esc(op.name)}</strong><small>${esc(op.incident_prefix||"")}</small></div>
        <div><span>ASSIGNED</span><strong>${unitAssigned}</strong></div>
        <div><span>CHECKED IN</span><strong>${checkedIn}/${expected}</strong></div>
        <div><span>NOT SCHEDULED</span><strong>${notScheduled.length}</strong></div>
      </div>

      <div class="staffing-command-actions">
        <button class="btn secondary" id="staffingFullscreen">Full Screen</button>
        <button class="btn secondary" id="staffingBack">Back to Dispatch</button>
      </div>
    </header>

    <div class="staffing-command-controls">
      <div class="staffing-op-selector">
        <label>Operational Period</label>
        <select id="staffingOperationalPeriod">
          ${activeOperationalPeriods(ctx).map(period=>`
            <option value="${period.id}" ${period.id===op.id?"selected":""}>
              ${esc(period.name)} · ${esc(period.status)}
            </option>
          `).join("")}
        </select>
      </div>

      <div class="nav staffing-board-actions">
        <button class="btn" id="staffingAddPersonnel">+ Add Personnel</button>
        <button class="btn secondary" id="staffingQuickAdd">Quick Add Names</button>
        <button class="btn secondary" id="staffingRoster">Personnel Roster</button>
        ${op.status==="COMPLETE"?"":`<button class="btn secondary" id="staffingCopyPeriod">Copy From Another OP</button>`}
        <button class="btn secondary" id="staffingExport">Export Staffing</button>
      </div>
    </div>

    <main class="staffing-board">
      <div class="staffing-op-banner">
        <div>
          <div class="section-title">STAFFING ASSIGNMENTS ARE OPERATIONAL-PERIOD SPECIFIC</div>
          <strong>${esc(op.name)}</strong>
          <span>${op.starts_at||op.ends_at?`${esc(dateTime24(op.starts_at))} → ${esc(dateTime24(op.ends_at))}`:"No planned start/end"}</span>
        </div>
        <span class="badge staffing-op-status">${esc(op.status)}</span>
      </div>

      ${poolAssignments.length?`
        <section class="staffing-department-section">
          <div class="staffing-department-heading">
            <div><div class="section-title">RESERVE / STAGING</div><h2>Personnel Pool</h2></div>
          </div>
          <div class="staffing-unit-grid">
            ${unassignedAssignmentCard(poolAssignments,state,ctx)}
          </div>
        </section>
      `:""}

      ${departmentSections}
    </main>
  </div>`;
}

function bindBoard(ctx,state){
  document.querySelector("#staffingBack").onclick=async()=>{
    if(staffingChannel){
      try{await supabase.removeChannel(staffingChannel);}catch{}
      staffingChannel=null;
    }
    ctx.onBack();
  };

  document.querySelector("#staffingFullscreen").onclick=async()=>{
    const shell=document.querySelector("#staffingCommandShell");
    try{
      if(!document.fullscreenElement)await shell.requestFullscreen();
      else await document.exitFullscreen();
    }catch(error){
      alert(`Full screen is not available in this browser: ${error.message}`);
    }
  };

  document.querySelector("#staffingOperationalPeriod").onchange=event=>{
    state.operationalPeriod=activeOperationalPeriods(ctx).find(op=>op.id===event.target.value)||state.operationalPeriod;
    saveSelectedOperationalPeriod(ctx.eventId,state.operationalPeriod.id);
    state.render();
  };

  document.querySelector("#staffingAddPersonnel").onclick=()=>personnelModal(ctx,state);
  document.querySelector("#staffingQuickAdd").onclick=()=>quickAddPersonnelModal(ctx,state);
  document.querySelector("#staffingRoster").onclick=()=>rosterModal(ctx,state);
  document.querySelector("#staffingCopyPeriod")?.addEventListener("click",()=>copyPeriodModal(ctx,state));

  document.querySelector("#staffingExport").onclick=()=>{
    const rows=exportRows(state,ctx);
    downloadCsv(
      `${ctx.event?.event_code||"event"}-${state.operationalPeriod?.incident_prefix||"op"}-unit-staffing.csv`,
      [
        {label:"Operational Period",value:()=>state.operationalPeriod?.name||""},
        {label:"Incident Prefix",value:()=>state.operationalPeriod?.incident_prefix||""},
        {label:"Department",value:r=>r.dep?.name||""},
        {label:"Unit",value:r=>r.unit?.name||"Unassigned / Reserve"},
        {label:"Personnel",value:r=>r.person?.full_name||""},
        {label:"Preferred Name",value:r=>r.person?.preferred_name||""},
        {label:"Personnel ID",value:r=>r.person?.personnel_identifier||""},
        {label:"Role",value:r=>r.assignment.role_label||""},
        {label:"Planned Start",value:r=>dateTime24(r.assignment.planned_start_at)},
        {label:"Planned End",value:r=>dateTime24(r.assignment.planned_end_at)},
        {label:"Status",value:r=>staffingStatusLabel(r.assignment.status)},
        {label:"Checked In",value:r=>dateTime24(r.assignment.checked_in_at)},
        {label:"Checked Out",value:r=>dateTime24(r.assignment.checked_out_at)},
        {label:"Notes",value:r=>r.assignment.notes||""}
      ],
      rows
    );
  };

  document.querySelectorAll("[data-staffing-add-unit]").forEach(button=>{
    button.onclick=()=>assignmentModal(ctx,state,{unitId:button.dataset.staffingAddUnit||null});
  });

  document.querySelectorAll("[data-staffing-assign-person]").forEach(button=>{
    button.onclick=()=>assignmentModal(ctx,state,{personnelId:button.dataset.staffingAssignPerson});
  });

  document.querySelectorAll("[data-staffing-edit-assignment]").forEach(button=>{
    const assignment=state.assignments.find(a=>a.id===button.dataset.staffingEditAssignment);
    button.onclick=()=>assignmentModal(ctx,state,{assignment});
  });

  document.querySelectorAll("[data-staffing-checkin]").forEach(button=>{
    button.onclick=async()=>{
      button.disabled=true;
      button.textContent="Checking In…";
      try{
        await checkAssignment(button.dataset.staffingCheckin,true,state);
      }catch(error){
        button.disabled=false;
        button.textContent="Check In";
        alert(error.message);
      }
    };
  });

  document.querySelectorAll("[data-staffing-checkout]").forEach(button=>{
    button.onclick=async()=>{
      button.disabled=true;
      button.textContent="Checking Out…";
      try{
        await checkAssignment(button.dataset.staffingCheckout,false,state);
      }catch(error){
        button.disabled=false;
        button.textContent="Check Out";
        alert(error.message);
      }
    };
  });

  document.querySelectorAll("[data-staffing-checkin-crew]").forEach(button=>{
    button.onclick=()=>checkCrew(button.dataset.staffingCheckinCrew,true,state);
  });

  document.querySelectorAll("[data-staffing-checkout-crew]").forEach(button=>{
    button.onclick=()=>checkCrew(button.dataset.staffingCheckoutCrew,false,state);
  });
}

export async function renderUnitStaffing(app,ctx){
  if(staffingChannel){
    try{await supabase.removeChannel(staffingChannel);}catch{}
    staffingChannel=null;
  }

  const periods=activeOperationalPeriods(ctx);
  if(!periods.length){
    app.innerHTML=`<div class="shell">${ctx.header(`${esc(ctx.event?.name||"Event")} · Unit Staffing`)}
      <div class="center"><div class="card stack">
        <h2>No Operational Periods</h2>
        <p class="muted">Unit staffing assignments must belong to an Operational Period. Create an Operational Period before building the staffing board.</p>
        <button class="btn" id="staffingCreatePeriod">Operational Periods</button>
        <button class="btn secondary" id="staffingNoPeriodBack">Back to Dispatch</button>
      </div></div>
    </div>`;

    document.querySelector("#staffingCreatePeriod").onclick=()=>ctx.onOperationalPeriods?.();
    document.querySelector("#staffingNoPeriodBack").onclick=ctx.onBack;
    return;
  }

  const state={
    people:[],
    assignments:[],
    periodAssignments:[],
    operationalPeriod:chooseInitialOperationalPeriod(ctx),
    reload:null,
    render:null
  };

  state.render=()=>{
    app.innerHTML=boardHtml(ctx,state);
    bindBoard(ctx,state);
  };

  state.reload=async()=>{
    const data=await fetchStaffingData(ctx.eventId);
    state.people=data.people;
    state.assignments=data.assignments;

    if(!activeOperationalPeriods(ctx).some(op=>op.id===state.operationalPeriod?.id)){
      state.operationalPeriod=chooseInitialOperationalPeriod(ctx);
    }

    state.render();
  };

  try{
    await state.reload();
  }catch(error){
    app.innerHTML=`<div class="shell">${ctx.header(`${esc(ctx.event?.name||"Event")} · Unit Staffing`)}
      <div class="center"><div class="card stack">
        <h2>Unit Staffing Unavailable</h2>
        <div class="notice error">${esc(error.message)}</div>
        <button class="btn secondary" id="staffingLoadBack">Back to Dispatch</button>
      </div></div>
    </div>`;
    document.querySelector("#staffingLoadBack").onclick=ctx.onBack;
    return;
  }

  staffingChannel=supabase.channel(`unit-staffing-${ctx.eventId}-${Date.now()}`)
    .on("postgres_changes",{
      event:"*",
      schema:"public",
      table:"event_personnel",
      filter:`event_id=eq.${ctx.eventId}`
    },()=>state.reload().catch(console.warn))
    .on("postgres_changes",{
      event:"*",
      schema:"public",
      table:"unit_staffing_assignments",
      filter:`event_id=eq.${ctx.eventId}`
    },()=>state.reload().catch(console.warn))
    .subscribe();
}
