import { supabase } from "./supabase.js";

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]));
const fmt=iso=>iso?new Date(iso).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"}):"";
const ageMinutes=iso=>iso?Math.max(0,Math.round((Date.now()-new Date(iso).getTime())/60000)):0;
const pretty=s=>String(s||"").replaceAll("_"," ");

let treatmentChannel=null;
let treatmentChannelKey=null;
let treatmentRefreshTimer=null;
let treatmentRealtimeGeneration=0;

let emsOpsChannel=null;
let emsOpsChannelKey=null;
let emsOpsRefreshTimer=null;
let emsOpsRealtimeGeneration=0;

async function clearTreatmentRealtime(){
  treatmentRealtimeGeneration++;
  if(treatmentRefreshTimer){
    clearTimeout(treatmentRefreshTimer);
    treatmentRefreshTimer=null;
  }
  const channel=treatmentChannel;
  treatmentChannel=null;
  treatmentChannelKey=null;
  if(channel){
    try{await supabase.removeChannel(channel);}catch(error){console.warn("Treatment Realtime cleanup warning",error);}
  }
}

async function clearEmsOpsRealtime(){
  emsOpsRealtimeGeneration++;
  if(emsOpsRefreshTimer){
    clearTimeout(emsOpsRefreshTimer);
    emsOpsRefreshTimer=null;
  }
  const channel=emsOpsChannel;
  emsOpsChannel=null;
  emsOpsChannelKey=null;
  if(channel){
    try{await supabase.removeChannel(channel);}catch(error){console.warn("EMS Ops Realtime cleanup warning",error);}
  }
}

async function ensureTreatmentRealtime(app,ts,area,ctx){
  const key=`${ts.event_id}:${area.id}`;

  // Re-renders of the treatment dashboard reuse the existing subscribed
  // channel. Supabase does not allow .on(postgres_changes) callbacks to be
  // added after subscribe(), which was the source of the v0.5.4 error.
  if(treatmentChannel&&treatmentChannelKey===key)return;

  await clearTreatmentRealtime();
  const generation=treatmentRealtimeGeneration;
  treatmentChannelKey=key;

  const refresh=()=>{
    if(generation!==treatmentRealtimeGeneration)return;
    if(treatmentRefreshTimer)clearTimeout(treatmentRefreshTimer);
    treatmentRefreshTimer=setTimeout(()=>{
      treatmentRefreshTimer=null;
      if(generation!==treatmentRealtimeGeneration)return;
      treatmentDashboard(app,ts,ctx);
    },250);
  };

  const channel=supabase.channel(`treatment-${ts.event_id}-${area.id}-${Date.now()}`)
    .on("postgres_changes",{event:"*",schema:"public",table:"ems_encounters",filter:`event_id=eq.${ts.event_id}`},refresh)
    .on("postgres_changes",{event:"*",schema:"public",table:"ems_handoffs",filter:`event_id=eq.${ts.event_id}`},refresh)
    .on("postgres_changes",{event:"*",schema:"public",table:"ems_treatment_areas",filter:`event_id=eq.${ts.event_id}`},refresh);

  treatmentChannel=channel;
  channel.subscribe(status=>{
    if(status==="CHANNEL_ERROR"||status==="TIMED_OUT"){
      console.warn(`Treatment Realtime status: ${status}`);
    }
  });
}

async function ensureEmsOpsRealtime(app,ctx){
  const key=String(ctx.eventId);
  if(emsOpsChannel&&emsOpsChannelKey===key)return;

  await clearEmsOpsRealtime();
  const generation=emsOpsRealtimeGeneration;
  emsOpsChannelKey=key;

  const refresh=()=>{
    if(generation!==emsOpsRealtimeGeneration)return;
    if(emsOpsRefreshTimer)clearTimeout(emsOpsRefreshTimer);
    emsOpsRefreshTimer=setTimeout(()=>{
      emsOpsRefreshTimer=null;
      if(generation!==emsOpsRealtimeGeneration)return;
      renderEmsOps(app,ctx,{preserveRealtime:true});
    },250);
  };

  const channel=supabase.channel(`ems-ops-${ctx.eventId}-${Date.now()}`)
    .on("postgres_changes",{event:"*",schema:"public",table:"ems_encounters",filter:`event_id=eq.${ctx.eventId}`},refresh)
    .on("postgres_changes",{event:"*",schema:"public",table:"ems_handoffs",filter:`event_id=eq.${ctx.eventId}`},refresh)
    .on("postgres_changes",{event:"*",schema:"public",table:"ems_treatment_areas",filter:`event_id=eq.${ctx.eventId}`},refresh);

  emsOpsChannel=channel;
  channel.subscribe(status=>{
    if(status==="CHANNEL_ERROR"||status==="TIMED_OUT"){
      console.warn(`EMS Ops Realtime status: ${status}`);
    }
  });
}

async function getUnitsAndConfigs(eventId){
  const [unitsRes,configRes]=await Promise.all([
    supabase.from("units").select("id,event_id,department_id,name,status,active").eq("event_id",eventId).eq("active",true).order("name"),
    supabase.from("ems_unit_config").select("*")
  ]);
  if(unitsRes.error)throw unitsRes.error;
  if(configRes.error)throw configRes.error;
  const configs=configRes.data||[];
  return (unitsRes.data||[]).map(u=>({...u,ems_config:configs.find(c=>c.unit_id===u.id)||null}));
}

function resourceName({unitId,areaId,units,areas}){
  if(unitId)return units.find(u=>u.id===unitId)?.name||"EMS Unit";
  if(areaId)return areas.find(a=>a.id===areaId)?.name||"Treatment Area";
  return "Unassigned";
}

async function getIncidentMap(ids){
  const uniq=[...new Set((ids||[]).filter(Boolean))];
  if(!uniq.length)return {};
  const {data,error}=await supabase.from("incidents").select("id,incident_number,call_type,landmark").in("id",uniq);
  if(error){console.warn("EMS incident lookup failed",error);return {};}
  return Object.fromEntries((data||[]).map(i=>[i.id,i]));
}


function encounterIncidentNumber(encounter,incidentMap){
  return incidentMap[encounter?.incident_id]?.incident_number || "EMS Incident";
}

function encounterIncidentNature(encounter,incidentMap){
  return incidentMap[encounter?.incident_id]?.call_type || "Medical";
}

/* ============================================================
   EMS COMMAND / DISPATCH BOARD
   ============================================================ */


export async function renderEmsOps(app,ctx,{preserveRealtime=false}={}){
  if(!preserveRealtime)await clearEmsOpsRealtime();
  const {eventId,event,header,onBack,onAdmin}=ctx;

  try{
    const [areasRes,encRes,handoffRes,units]=await Promise.all([
      supabase.from("ems_treatment_areas").select("*").eq("event_id",eventId).eq("active",true).order("name"),
      supabase.from("ems_encounters").select("*").eq("event_id",eventId).neq("current_status","CLOSED").order("created_at"),
      supabase.from("ems_handoffs").select("*").eq("event_id",eventId).eq("status","COMPLETED").order("completed_at",{ascending:false}).limit(20),
      getUnitsAndConfigs(eventId)
    ]);
    if(areasRes.error)throw areasRes.error;
    if(encRes.error)throw encRes.error;
    if(handoffRes.error)throw handoffRes.error;

    const areas=areasRes.data||[];
    const encounters=encRes.data||[];
    const handoffs=handoffRes.data||[];
    const incidents=await getIncidentMap(encounters.map(e=>e.incident_id));
    const ambulances=units.filter(u=>u.ems_config?.active&&(u.ems_config.ems_role==="ambulance"||u.ems_config.transport_capable));
    const fieldTeams=units.filter(u=>u.ems_config?.active&&u.ems_config.ems_role==="field_team");

    const fieldCount=encounters.filter(e=>e.current_status==="FIELD").length;
    const treatmentCount=encounters.filter(e=>e.current_status==="IN_TREATMENT").length;
    const ambulanceCount=encounters.filter(e=>["WITH_AMBULANCE","TRANSPORTING"].includes(e.current_status)).length;

    app.innerHTML=`<div class="shell">${header(`${esc(event?.name||"Event")} · EMS Operations`)}
      <div class="wrap stack ems-ops-wrap">
        <div class="row"><h2>EMS Operations</h2><div class="nav"><button class="btn secondary" id="emsAdmin">EMS Setup</button><button class="btn secondary" id="emsBack">Back to CAD</button></div></div>

        <div class="ems-metrics">
          <div class="card"><div class="metric">${encounters.length}</div><div class="small muted">Active EMS Incidents</div></div>
          <div class="card"><div class="metric">${fieldCount}</div><div class="small muted">With Field Teams</div></div>
          <div class="card"><div class="metric">${treatmentCount}</div><div class="small muted">In Treatment</div></div>
          <div class="card"><div class="metric">${ambulanceCount}</div><div class="small muted">With Ambulances</div></div>
        </div>

        <div class="grid2 ems-board-grid">
          <section class="card">
            <h3>Treatment Areas</h3>
            ${areas.map(a=>{
              const count=encounters.filter(e=>e.current_treatment_area_id===a.id).length;
              const pct=Math.min(100,Math.round(count/a.capacity*100));
              return `<div class="ems-resource-card">
                <div class="row"><strong>${esc(a.name)}</strong><span class="badge ta-${esc(a.status)}">${esc(a.status)}</span></div>
                <div class="row"><span>${count} / ${a.capacity} occupied</span><span class="small muted">${a.accepting_patients?"Accepting":"Not accepting"}</span></div>
                <div class="progress"><div style="width:${pct}%"></div></div>
              </div>`;
            }).join("")||`<div class="muted">No treatment areas configured.</div>`}
          </section>

          <section class="card">
            <h3>Ambulances</h3>
            ${ambulances.map(u=>{
              const pts=encounters.filter(e=>e.current_unit_id===u.id);
              return `<div class="ems-resource-card">
                <div class="row"><strong>${esc(u.name)}</strong><span class="badge status-${esc(u.status)}">${esc(pretty(u.status))}</span></div>
                <div class="small muted">${esc(u.ems_config?.ambulance_level||"Transport")} · ${pts.length?pts.map(p=>esc(encounterIncidentNumber(p,incidents))).join(", "):"No patient"}</div>
              </div>`;
            }).join("")||`<div class="muted">No ambulances configured.</div>`}
          </section>
        </div>

        <section class="card">
          <div class="row"><h3>Active EMS Patient Flow</h3><span class="small muted">Incident number is the patient reference</span></div>
          <div class="table-wrap"><table><thead><tr><th>Incident</th><th>Nature</th><th>Status</th><th>Current Custody</th><th>Age</th><th>Note</th></tr></thead><tbody>
            ${encounters.map(e=>`<tr>
              <td><strong>${esc(encounterIncidentNumber(e,incidents))}</strong></td>
              <td>${esc(encounterIncidentNature(e,incidents))}</td>
              <td>${esc(pretty(e.current_status))}</td>
              <td>${esc(resourceName({unitId:e.current_unit_id,areaId:e.current_treatment_area_id,units,areas}))}</td>
              <td>${ageMinutes(e.created_at)} min</td>
              <td>${esc(e.operational_note||"")}</td>
            </tr>`).join("")||`<tr><td colspan="6" class="muted">No active EMS incidents.</td></tr>`}
          </tbody></table></div>
        </section>

        <section class="card">
          <h3>EMS Resources & Recent Transfers</h3>
          <div class="grid2">
            <div>
              <div class="section-title">Field Teams</div>
              ${fieldTeams.map(u=>`<div class="unit"><div class="row"><strong>${esc(u.name)}</strong><span class="badge status-${esc(u.status)}">${esc(pretty(u.status))}</span></div></div>`).join("")||`<div class="muted">None configured.</div>`}
            </div>
            <div>
              <div class="section-title">Recent Direct Handoffs</div>
              ${handoffs.slice(0,10).map(h=>`<div class="small" style="padding:6px 0;border-bottom:1px solid #334155">
                <strong>${fmt(h.completed_at||h.responded_at||h.requested_at)}</strong> ·
                ${esc(resourceName({unitId:h.from_unit_id,areaId:h.from_treatment_area_id,units,areas}))}
                → ${esc(resourceName({unitId:h.to_unit_id,areaId:h.to_treatment_area_id,units,areas}))}
              </div>`).join("")||`<div class="muted">No completed handoffs yet.</div>`}
            </div>
          </div>
        </section>
      </div>
    </div>`;

    document.querySelector("#emsBack").onclick=async()=>{await clearEmsOpsRealtime();onBack();};
    document.querySelector("#emsAdmin").onclick=async()=>{await clearEmsOpsRealtime();onAdmin();};

    await ensureEmsOpsRealtime(app,ctx);
  }catch(err){
    console.error("EMS Ops load error",err);
    app.innerHTML=`<div class="shell">${header("EMS Operations Error")}<div class="wrap"><div class="notice error"><strong>EMS Operations could not load.</strong><br>${esc(err.message)}</div><button class="btn" id="emsBack">Back to CAD</button></div></div>`;
    document.querySelector("#emsBack").onclick=onBack;
  }
}



export async function renderDispatchIncidentTreatmentPanel(container,{eventId,incidentId,onBack}){
  try{
    const [incidentRes,areasRes,encRes,units]=await Promise.all([
      supabase.from("incidents").select("id,incident_number,call_type,priority,landmark").eq("id",incidentId).single(),
      supabase.from("ems_treatment_areas").select("*").eq("event_id",eventId).eq("active",true).order("name"),
      supabase.from("ems_encounters").select("*").eq("event_id",eventId).eq("incident_id",incidentId).neq("current_status","CLOSED").order("created_at").limit(1).maybeSingle(),
      getUnitsAndConfigs(eventId)
    ]);

    for(const r of [incidentRes,areasRes,encRes])if(r.error)throw r.error;

    const incident=incidentRes.data;
    const areas=areasRes.data||[];
    const encounter=encRes.data||null;
    const ambulances=units.filter(u=>u.ems_config?.active&&(u.ems_config.ems_role==="ambulance"||u.ems_config.transport_capable));
    const current=encounter
      ? resourceName({unitId:encounter.current_unit_id,areaId:encounter.current_treatment_area_id,units,areas})
      : "No EMS custody recorded";

    container.innerHTML=`<div class="card stack treatment-dispatch-panel">
      <div class="row">
        <div>
          <div class="section-title">EMS Handoff / Custody</div>
          <strong>${esc(incident.incident_number)} · ${esc(incident.call_type)}</strong>
        </div>
        <button class="btn secondary" id="emsTreatmentBack">Back</button>
      </div>

      <div class="notice">
        <strong>Current EMS custody</strong><br>
        ${esc(current)}${encounter?` · ${esc(pretty(encounter.current_status))}`:""}
      </div>

      <div class="grid2 direct-handoff-grid">
        <section class="direct-handoff-option">
          <label>Hand off to treatment area</label>
          <select id="dispatchTreatmentArea">
            <option value="">Choose treatment area</option>
            ${areas.filter(a=>a.accepting_patients&&!["FULL","CLOSED"].includes(a.status)).map(a=>`<option value="${a.id}">${esc(a.name)} · ${esc(a.status)}</option>`).join("")}
          </select>
          <button class="btn good block" id="dispatchMarkTreatment">Hand Off to Treatment Area</button>
        </section>

        <section class="direct-handoff-option">
          <label>Hand off to ambulance</label>
          <select id="dispatchAmbulance">
            <option value="">Choose ambulance</option>
            ${ambulances.map(a=>`<option value="${a.id}">${esc(a.name)} · ${esc(pretty(a.status))}</option>`).join("")}
          </select>
          <button class="btn good block" id="dispatchMarkAmbulance">Hand Off to Ambulance</button>
        </section>
      </div>

      <div><label>Operational note</label><input id="dispatchCustodyNote" placeholder="Optional note"></div>

      <div class="small muted">Handoffs take effect immediately. The receiving resource does not need to accept a request.</div>
    </div>`;

    document.querySelector("#emsTreatmentBack").onclick=onBack;

    const transfer=async({areaId=null,unitId=null})=>{
      const destination=areaId
        ? areas.find(a=>a.id===areaId)?.name
        : ambulances.find(a=>a.id===unitId)?.name;
      if(!destination)return alert("Choose a destination.");
      if(!confirm(`Hand off ${incident.incident_number} to ${destination}?`))return;

      const {data,error}=await supabase.rpc("ems_dispatch_set_incident_custody",{
        p_incident_id:incident.id,
        p_to_unit_id:unitId,
        p_to_treatment_area_id:areaId,
        p_note:document.querySelector("#dispatchCustodyNote").value.trim()||null
      });
      if(error)return alert(error.message);

      alert(data==="ALREADY_HERE"
        ? `${incident.incident_number} is already recorded with ${destination}.`
        : `${incident.incident_number} is now in the custody of ${destination}.`);
      onBack();
    };

    document.querySelector("#dispatchMarkTreatment").onclick=()=>{
      const areaId=document.querySelector("#dispatchTreatmentArea").value||null;
      transfer({areaId});
    };

    document.querySelector("#dispatchMarkAmbulance").onclick=()=>{
      const unitId=document.querySelector("#dispatchAmbulance").value||null;
      transfer({unitId});
    };
  }catch(error){
    container.innerHTML=`<div class="card stack"><div class="notice error">${esc(error.message)}</div><button class="btn secondary" id="emsTreatmentBack">Back</button></div>`;
    document.querySelector("#emsTreatmentBack").onclick=onBack;
  }
}

/* ============================================================
   EMS EVENT ADMIN
   ============================================================ */

export async function renderEmsAdmin(container,ctx,onRefresh){
  const {eventId,event,units,pois,departments}=ctx;
  const [areasRes,configRes]=await Promise.all([
    supabase.from("ems_treatment_areas").select("*").eq("event_id",eventId).eq("active",true).order("name"),
    supabase.from("ems_unit_config").select("*")
  ]);
  if(areasRes.error)return container.innerHTML=`<div class="notice error">${esc(areasRes.error.message)}</div>`;
  if(configRes.error)return container.innerHTML=`<div class="notice error">${esc(configRes.error.message)}</div>`;
  const areas=areasRes.data||[];
  const configs=configRes.data||[];

  container.innerHTML=`<div class="stack">
    <div class="card">
      <h2>EMS Treatment Areas</h2>
      <p class="muted">Treatment areas are stationary EMS receiving locations. Their tablets use the event ID/PIN and then select a treatment area.</p>
      ${areas.map(a=>`<div class="ems-admin-row">
        <div><strong>${esc(a.name)}</strong><div class="small muted">Capacity ${a.capacity} · ${esc(a.status)} · ${a.accepting_patients?"Accepting":"Not accepting"}${a.poi_id?` · POI ${esc(pois.find(p=>p.id===a.poi_id)?.name||"")}`:""}</div></div>
        <button class="btn secondary" data-disable-area="${a.id}">Disable</button>
      </div>`).join("")||`<div class="muted">No treatment areas configured.</div>`}
      <hr>
      <div class="grid2">
        <div><label>Name</label><input id="taName" placeholder="Treatment area name"></div>
        <div><label>Capacity</label><input id="taCapacity" type="number" min="1" value="12"></div>
        <div><label>Department</label><select id="taDept"><option value="">No department link</option>${departments.map(d=>`<option value="${d.id}">${esc(d.name)}</option>`).join("")}</select></div>
        <div><label>POI / common location</label><select id="taPoi"><option value="">No POI</option>${pois.map(p=>`<option value="${p.id}">${esc(p.name)}</option>`).join("")}</select></div>
      </div>
      <div><label>Notes</label><input id="taNotes" placeholder="Optional notes"></div>
      <button class="btn" id="addTreatmentArea">Add Treatment Area</button>
    </div>

    <div class="card">
      <h2>EMS Unit Roles</h2>
      <p class="muted">Classify existing CAD units as field teams, ambulances, or EMS command. Only transport-capable units appear as ambulance handoff destinations.</p>
      <div class="table-wrap"><table><thead><tr><th>Unit</th><th>EMS Role</th><th>Transport</th><th>Level</th><th></th></tr></thead><tbody>
        ${units.map(u=>{
          const c=configs.find(x=>x.unit_id===u.id);
          return `<tr><td><strong>${esc(u.name)}</strong></td>
            <td><select id="role-${u.id}"><option value="">Not EMS-tracked</option><option value="field_team" ${c?.ems_role==="field_team"?"selected":""}>Field Team</option><option value="ambulance" ${c?.ems_role==="ambulance"?"selected":""}>Ambulance</option><option value="command" ${c?.ems_role==="command"?"selected":""}>EMS Command</option></select></td>
            <td><input id="transport-${u.id}" type="checkbox" ${c?.transport_capable?"checked":""}></td>
            <td><select id="level-${u.id}"><option value="">—</option>${["BLS","ALS","CCT","OTHER"].map(l=>`<option ${c?.ambulance_level===l?"selected":""}>${l}</option>`).join("")}</select></td>
            <td><button class="btn secondary" data-save-ems-unit="${u.id}">Save</button></td></tr>`;
        }).join("")}
      </tbody></table></div>
    </div>

    <div class="card">
      <h2>Treatment Area Station Login</h2>
      <p>On the treatment-area tablet:</p>
      <div class="notice ok"><strong>CommCenter Pro → Treatment Area Station</strong><br>Event ID: <span class="mono">${esc(event?.event_code||"")}</span><br>Use the same 4-digit field PIN configured for the event, then select the treatment area.</div>
    </div>
  </div>`;

  document.querySelector("#addTreatmentArea").onclick=async()=>{
    const name=document.querySelector("#taName").value.trim();
    const capacity=Number(document.querySelector("#taCapacity").value);
    if(!name||!Number.isInteger(capacity)||capacity<1)return alert("Enter a treatment-area name and capacity of at least 1.");
    const {error}=await supabase.from("ems_treatment_areas").insert({
      event_id:eventId,
      department_id:document.querySelector("#taDept").value||null,
      poi_id:document.querySelector("#taPoi").value||null,
      name,capacity,notes:document.querySelector("#taNotes").value.trim()||null
    });
    if(error)return alert(error.message);
    await onRefresh();
  };

  document.querySelectorAll("[data-disable-area]").forEach(b=>b.onclick=async()=>{
    if(!confirm("Disable this treatment area? Existing encounter history will be preserved."))return;
    const {error}=await supabase.from("ems_treatment_areas").update({active:false,accepting_patients:false,status:"CLOSED"}).eq("id",b.dataset.disableArea);
    if(error)alert(error.message);else await onRefresh();
  });

  document.querySelectorAll("[data-save-ems-unit]").forEach(b=>b.onclick=async()=>{
    const unitId=b.dataset.saveEmsUnit;
    const role=document.querySelector(`#role-${unitId}`).value;
    if(!role){
      const {error}=await supabase.from("ems_unit_config").delete().eq("unit_id",unitId);
      if(error)alert(error.message);else await onRefresh();
      return;
    }
    const {error}=await supabase.from("ems_unit_config").upsert({
      unit_id:unitId,ems_role:role,
      transport_capable:role==="ambulance"||document.querySelector(`#transport-${unitId}`).checked,
      ambulance_level:document.querySelector(`#level-${unitId}`).value||null,
      active:true
    },{onConflict:"unit_id"});
    if(error)alert(error.message);else await onRefresh();
  });
}

/* ============================================================
   FIELD EMS PANEL
   ============================================================ */


export async function loadFieldEmsState(eventId,unitId,incidentId){
  const {data:config,error:configErr}=await supabase.from("ems_unit_config").select("*").eq("unit_id",unitId).maybeSingle();
  if(configErr)throw configErr;
  if(!config?.active)return null;

  const [encRes,areasRes,units]=await Promise.all([
    supabase.from("ems_encounters").select("*").eq("current_unit_id",unitId).neq("current_status","CLOSED").order("created_at"),
    supabase.from("ems_treatment_areas").select("*").eq("event_id",eventId).eq("active",true).order("name"),
    getUnitsAndConfigs(eventId)
  ]);
  for(const r of [encRes,areasRes])if(r.error)throw r.error;

  const current=encRes.data||[];
  const areas=areasRes.data||[];
  const ambulances=units.filter(u=>u.id!==unitId&&u.ems_config?.active&&(u.ems_config.ems_role==="ambulance"||u.ems_config.transport_capable));
  const incidentMap=await getIncidentMap(current.map(e=>e.incident_id));

  return {config,current,areas,units,ambulances,incidentId,incidentMap};
}

export function fieldEmsPanelHtml(state,incident){
  if(!state)return "";
  const activeForIncident=incident ? state.current.find(e=>e.incident_id===incident.id) : null;

  return `<div class="card ems-panel">
    <div class="row">
      <div>
        <div class="section-title">EMS Patient Flow</div>
        <strong>${state.config.ems_role==="ambulance"?"Ambulance Custody":state.config.ems_role==="field_team"?"Field Handoff Operations":"EMS Command Resource"}</strong>
      </div>
      <span class="badge">${esc(pretty(state.config.ems_role))}</span>
    </div>

    ${state.current.map(e=>`
      <div class="patient-card">
        <div class="row">
          <div>
            <div class="big">${esc(encounterIncidentNumber(e,state.incidentMap))}</div>
            <div class="small muted">${esc(encounterIncidentNature(e,state.incidentMap))} · ${ageMinutes(e.created_at)} min in EMS flow</div>
          </div>
          <span class="badge">${esc(pretty(e.current_status))}</span>
        </div>
        ${e.operational_note?`<p>${esc(e.operational_note)}</p>`:""}
        ${fieldEncounterActions(e,state)}
      </div>
    `).join("")}

    ${incident&&state.config.ems_role==="field_team"&&!activeForIncident?`
      <div class="patient-card">
        <div class="row">
          <div>
            <div class="big">${esc(incident.incident_number)}</div>
            <div class="small muted">${esc(incident.call_type)} · current incident</div>
          </div>
          <span class="badge">FIELD</span>
        </div>
        <p class="small muted">Choose where the patient was handed off. The custody change is recorded immediately.</p>
        <div class="stack">
          <div>
            <label>Hand off to treatment area</label>
            <div class="grid2">
              <select id="new-ta-${incident.id}">
                <option value="">Choose treatment area</option>
                ${state.areas.filter(a=>a.accepting_patients&&!["FULL","CLOSED"].includes(a.status)).map(a=>`<option value="${a.id}">${esc(a.name)} · ${a.status}</option>`).join("")}
              </select>
              <button class="btn" data-new-handoff-ta="${incident.id}">Hand Off</button>
            </div>
          </div>
          <div>
            <label>Hand off to ambulance</label>
            <div class="grid2">
              <select id="new-amb-${incident.id}">
                <option value="">Choose ambulance</option>
                ${state.ambulances.map(a=>`<option value="${a.id}">${esc(a.name)} · ${esc(pretty(a.status))}</option>`).join("")}
              </select>
              <button class="btn" data-new-handoff-amb="${incident.id}">Hand Off</button>
            </div>
          </div>
        </div>
      </div>`:""}

    ${!state.current.length&&!(incident&&state.config.ems_role==="field_team")?`<p class="muted">No EMS incident currently in this unit's custody.</p>`:""}
  </div>`;
}

function fieldEncounterActions(e,state){
  if(state.config.ems_role==="ambulance"||state.config.transport_capable){
    if(e.current_status==="TRANSPORTING"){
      return `<div class="stack">
        ${e.transport_destination?`<div class="notice"><strong>Destination</strong><br>${esc(e.transport_destination)}</div>`:""}
        <button class="btn good" data-complete-transport="${e.id}">Complete Transport</button>
      </div>`;
    }
    return `<div class="stack">
      <div class="small muted">Use the unit status controls below and choose TRANSPORTING to enter the destination facility and start transport.</div>
      <button class="btn secondary" data-release-encounter="${e.id}">Close / Other Disposition</button>
    </div>`;
  }

  if(state.config.ems_role==="field_team"){
    return `<div class="stack">
      <div>
        <label>Hand off to treatment area</label>
        <div class="grid2">
          <select id="ta-${e.id}">
            <option value="">Choose treatment area</option>
            ${state.areas.filter(a=>a.accepting_patients&&!["FULL","CLOSED"].includes(a.status)).map(a=>`<option value="${a.id}">${esc(a.name)} · ${a.status}</option>`).join("")}
          </select>
          <button class="btn" data-handoff-ta="${e.id}">Hand Off</button>
        </div>
      </div>
      <div>
        <label>Hand off to ambulance</label>
        <div class="grid2">
          <select id="amb-${e.id}">
            <option value="">Choose ambulance</option>
            ${state.ambulances.map(a=>`<option value="${a.id}">${esc(a.name)} · ${esc(pretty(a.status))}</option>`).join("")}
          </select>
          <button class="btn" data-handoff-amb="${e.id}">Hand Off</button>
        </div>
      </div>
      <button class="btn secondary" data-release-encounter="${e.id}">Close EMS Flow</button>
    </div>`;
  }

  return `<div class="muted small">No patient-custody actions are configured for this resource.</div>`;
}

export function bindFieldEmsPanel(state,{eventId,unitId,incident,refresh}){
  if(!state)return;

  const createAndTransfer=async({incidentId,toUnitId=null,toTreatmentAreaId=null})=>{
    const createResult=await supabase.rpc("ems_create_encounter",{
      p_event_id:eventId,
      p_incident_id:incidentId,
      p_source_unit_id:unitId,
      p_source_treatment_area_id:null,
      p_operational_note:null
    });
    if(createResult.error)return alert(createResult.error.message);

    const transferResult=await supabase.rpc("ems_transfer_custody",{
      p_encounter_id:createResult.data,
      p_to_unit_id:toUnitId,
      p_to_treatment_area_id:toTreatmentAreaId,
      p_note:null
    });
    if(transferResult.error)return alert(transferResult.error.message);
    await refresh();
  };

  document.querySelectorAll("[data-new-handoff-ta]").forEach(b=>b.onclick=async()=>{
    const incidentId=b.dataset.newHandoffTa;
    const ta=document.querySelector(`#new-ta-${incidentId}`).value;
    if(!ta)return alert("Choose a treatment area.");
    if(!confirm("Confirm patient handoff to the selected treatment area?"))return;
    await createAndTransfer({incidentId,toTreatmentAreaId:ta});
  });

  document.querySelectorAll("[data-new-handoff-amb]").forEach(b=>b.onclick=async()=>{
    const incidentId=b.dataset.newHandoffAmb;
    const amb=document.querySelector(`#new-amb-${incidentId}`).value;
    if(!amb)return alert("Choose an ambulance.");
    if(!confirm("Confirm patient handoff to the selected ambulance?"))return;
    await createAndTransfer({incidentId,toUnitId:amb});
  });

  document.querySelectorAll("[data-handoff-ta]").forEach(b=>b.onclick=async()=>{
    const id=b.dataset.handoffTa;
    const ta=document.querySelector(`#ta-${id}`).value;
    if(!ta)return alert("Choose a treatment area.");
    if(!confirm("Confirm patient handoff to the selected treatment area?"))return;
    const {error}=await supabase.rpc("ems_transfer_custody",{
      p_encounter_id:id,p_to_unit_id:null,p_to_treatment_area_id:ta,p_note:null
    });
    if(error)alert(error.message);else await refresh();
  });

  document.querySelectorAll("[data-handoff-amb]").forEach(b=>b.onclick=async()=>{
    const id=b.dataset.handoffAmb;
    const amb=document.querySelector(`#amb-${id}`).value;
    if(!amb)return alert("Choose an ambulance.");
    if(!confirm("Confirm patient handoff to the selected ambulance?"))return;
    const {error}=await supabase.rpc("ems_transfer_custody",{
      p_encounter_id:id,p_to_unit_id:amb,p_to_treatment_area_id:null,p_note:null
    });
    if(error)alert(error.message);else await refresh();
  });

  document.querySelectorAll("[data-release-encounter]").forEach(b=>b.onclick=async()=>{
    const disp=prompt("Operational disposition:",state.config.ems_role==="field_team"?"RELEASED_ON_SCENE":"CLOSED")||"CLOSED";
    const {error}=await supabase.rpc("ems_release_encounter",{p_encounter_id:b.dataset.releaseEncounter,p_disposition:disp});
    if(error)alert(error.message);else await refresh();
  });


  document.querySelectorAll("[data-complete-transport]").forEach(b=>b.onclick=async()=>{
    if(!confirm("Mark transport complete and close this EMS flow?"))return;
    const {error}=await supabase.rpc("ems_complete_transport",{p_encounter_id:b.dataset.completeTransport,p_destination:null});
    if(error)alert(error.message);else await refresh();
  });
}

/* ============================================================
   TREATMENT AREA STATION
   ============================================================ */

export async function renderTreatmentAreaFlow(app,ctx){
  await clearTreatmentRealtime();
  const {header,onExit}=ctx;
  let {data:{session}}=await supabase.auth.getSession();
  if(!session||!session.user?.is_anonymous){
    if(session)await supabase.auth.signOut();
    const result=await supabase.auth.signInAnonymously();
    if(result.error)return treatmentError(app,header,result.error.message,onExit);
    session=result.data.session;
  }

  const {data:ts,error}=await supabase.from("treatment_area_sessions").select("*").eq("auth_user_id",session.user.id).eq("active",true).order("started_at",{ascending:false}).limit(1).maybeSingle();
  if(error)return treatmentError(app,header,error.message,onExit);
  if(!ts)return treatmentJoin(app,{header,onExit});
  if(!ts.treatment_area_id)return treatmentPicker(app,ts,{header,onExit});
  return treatmentDashboard(app,ts,{header,onExit});
}

function treatmentError(app,header,message,onExit){
  app.innerHTML=`<div class="shell">${header("Treatment Area Error")}<div class="center"><div class="card stack"><div class="notice error">${esc(message)}</div><button class="btn" id="tExit">Back</button></div></div></div>`;
  document.querySelector("#tExit").onclick=onExit;
}

function treatmentJoin(app,{header,onExit}){
  app.innerHTML=`<div class="shell">${header("Treatment Area Station")}<div class="center"><div class="card stack">
    <h2>Treatment Area Station</h2><p class="muted">Use this on the tablet or computer located at the treatment area.</p>
    <div><label>Event ID</label><input id="tEventCode" placeholder="Event code"></div>
    <div><label>4-digit access code</label><input id="tPin" maxlength="4" inputmode="numeric" placeholder="••••"></div>
    <div><label>Operator / station name (optional)</label><input id="tOperator" placeholder="Operator or station name"></div>
    <button class="btn" id="tJoin">Continue</button><button class="btn secondary" id="tExit">Back</button><div id="tErr" class="small muted"></div>
  </div></div></div>`;
  document.querySelector("#tExit").onclick=async()=>{await supabase.auth.signOut();onExit();};
  document.querySelector("#tJoin").onclick=async()=>{
    const {error}=await supabase.rpc("treatment_enter_event",{p_event_code:document.querySelector("#tEventCode").value.trim().toUpperCase(),p_pin:document.querySelector("#tPin").value.trim(),p_operator_name:document.querySelector("#tOperator").value.trim()});
    if(error)return document.querySelector("#tErr").textContent=error.message;
    renderTreatmentAreaFlow(app,{header,onExit});
  };
}

async function treatmentPicker(app,ts,{header,onExit}){
  const [eventRes,areasRes]=await Promise.all([
    supabase.from("events").select("id,name,event_code").eq("id",ts.event_id).single(),
    supabase.from("ems_treatment_areas").select("*").eq("event_id",ts.event_id).eq("active",true).order("name")
  ]);
  if(eventRes.error)return treatmentError(app,header,eventRes.error.message,onExit);
  if(areasRes.error)return treatmentError(app,header,areasRes.error.message,onExit);
  app.innerHTML=`<div class="shell">${header(`${esc(eventRes.data.name)} · Treatment Areas`)}<div class="wrap stack"><h2>Select Treatment Area</h2>
    <div class="grid2">${(areasRes.data||[]).map(a=>`<button class="choice" data-claim-area="${a.id}"><strong>${esc(a.name)}</strong><br><span class="badge ta-${esc(a.status)}">${esc(a.status)}</span> <span class="muted">Capacity ${a.capacity}</span></button>`).join("")||`<div class="card">No active treatment areas are configured. Ask Event Admin to create one.</div>`}</div>
    <button class="btn secondary" id="tLeave">Leave Event</button></div></div>`;
  document.querySelectorAll("[data-claim-area]").forEach(b=>b.onclick=async()=>{
    const {error}=await supabase.rpc("treatment_claim_area",{p_treatment_session_id:ts.id,p_treatment_area_id:b.dataset.claimArea});if(error)alert(error.message);else renderTreatmentAreaFlow(app,{header,onExit});
  });
  document.querySelector("#tLeave").onclick=async()=>{await clearTreatmentRealtime();await supabase.rpc("treatment_end_session",{p_treatment_session_id:ts.id});await supabase.auth.signOut();onExit();};
}


async function treatmentDashboard(app,ts,{header,onExit}){
  try{
    const [eventRes,areaRes,encRes,units]=await Promise.all([
      supabase.from("events").select("id,name,event_code").eq("id",ts.event_id).single(),
      supabase.from("ems_treatment_areas").select("*").eq("id",ts.treatment_area_id).single(),
      supabase.from("ems_encounters").select("*").eq("current_treatment_area_id",ts.treatment_area_id).neq("current_status","CLOSED").order("created_at"),
      getUnitsAndConfigs(ts.event_id)
    ]);

    for(const r of [eventRes,areaRes,encRes])if(r.error)throw r.error;

    const event=eventRes.data;
    const area=areaRes.data;
    const encounters=encRes.data||[];
    const ambulances=units.filter(u=>u.ems_config?.active&&(u.ems_config.ems_role==="ambulance"||u.ems_config.transport_capable));
    const incidentMap=await getIncidentMap(encounters.map(e=>e.incident_id));
    const occupancy=encounters.length;
    const pct=Math.min(100,Math.round(occupancy/area.capacity*100));

    app.innerHTML=`<div class="shell">${header(`${esc(event.name)} · ${esc(area.name)}`)}
      <div class="treatment-shell stack">
        <div class="treatment-header card">
          <div><div class="small muted">Treatment Area Station</div><div class="big">${esc(area.name)}</div></div>
          <div class="treatment-capacity">
            <div class="metric">${occupancy} / ${area.capacity}</div>
            <div class="small muted">Current occupancy</div>
            <div class="progress"><div style="width:${pct}%"></div></div>
          </div>
          <div><span class="badge ta-${esc(area.status)}">${esc(area.status)}</span><div class="small muted">${area.accepting_patients?"Accepting patients":"Not accepting patients"}</div></div>
        </div>

        <div class="grid2 treatment-top-grid">
          <div class="card">
            <h3>Station Status</h3>
            <div class="grid2">
              <select id="taStatus">
                <option ${area.status==="OPEN"?"selected":""}>OPEN</option>
                <option ${area.status==="LIMITED"?"selected":""}>LIMITED</option>
                <option ${area.status==="FULL"?"selected":""}>FULL</option>
                <option ${area.status==="CLOSED"?"selected":""}>CLOSED</option>
              </select>
              <label style="font-weight:500"><input type="checkbox" id="taAccepting" ${area.accepting_patients?"checked":""}> Accepting patients</label>
            </div>
            <button class="btn secondary" id="saveTaStatus">Update Status</button>
          </div>

          <div class="card">
            <h3>Walk-In Patient</h3>
            <p class="small muted">Creates a CAD incident and places the patient in this treatment area.</p>
            <input id="walkinNature" value="Walk-In Medical" placeholder="Call type / nature">
            <input id="walkinNote" placeholder="Optional note" style="margin-top:7px">
            <button class="btn" id="createWalkin">+ Create Walk-In Incident</button>
          </div>
        </div>

        <section class="card receive-existing-card">
          <div class="row">
            <div>
              <h3>Receive Existing Patient</h3>
              <div class="small muted">Search an active incident and mark the patient as physically received here.</div>
            </div>
            <span class="badge">INCIDENT #</span>
          </div>
          <div class="grid2">
            <input id="treatmentIncidentSearch" autocomplete="off" placeholder="Search incident, call type, or location">
            <button class="btn secondary" id="treatmentSearchBtn">Search Incidents</button>
          </div>
          <div id="treatmentIncidentResults" class="treatment-incident-results">
            <div class="small muted">Search for an active incident to receive a patient.</div>
          </div>
        </section>

        <section class="card">
          <div class="row"><h2>Patients in Treatment</h2><span class="badge">${encounters.length}</span></div>
          <div class="treatment-patient-grid">
            ${encounters.map(e=>{
              const inc=incidentMap[e.incident_id];
              return `<div class="treatment-patient-card">
                <div class="row">
                  <div>
                    <div class="big">${esc(inc?.incident_number||"EMS Incident")}</div>
                    <div class="small muted">${esc(inc?.call_type||"Medical")} · ${ageMinutes(e.created_at)} min in treatment</div>
                  </div>
                  <span class="badge">IN TREATMENT</span>
                </div>
                ${inc?.landmark?`<div class="small">Origin: ${esc(inc.landmark)}</div>`:""}
                ${e.operational_note?`<p>${esc(e.operational_note)}</p>`:""}
                <div class="stack">
                  <div>
                    <label>Hand off to ambulance</label>
                    <div class="grid2">
                      <select id="ta-amb-${e.id}">
                        <option value="">Choose ambulance</option>
                        ${ambulances.map(a=>`<option value="${a.id}">${esc(a.name)} · ${esc(pretty(a.status))}</option>`).join("")}
                      </select>
                      <button class="btn" data-ta-transfer-amb="${e.id}">Hand Off</button>
                    </div>
                  </div>
                  <button class="btn secondary" data-ta-release="${e.id}">Release / Close Patient</button>
                </div>
              </div>`;
            }).join("")||`<div class="muted">No patients currently in this treatment area.</div>`}
          </div>
        </section>

        <div class="row">
          <div class="nav">
            <button class="btn secondary" id="taRefresh">Refresh</button>
            <button class="btn secondary" id="taChange">Change Treatment Area</button>
            <button class="btn secondary" id="taLeave">Leave Event</button>
          </div>
        </div>
      </div>
    </div>`;

    document.querySelector("#saveTaStatus").onclick=async()=>{
      const {error}=await supabase.rpc("treatment_set_status",{
        p_treatment_area_id:area.id,
        p_status:document.querySelector("#taStatus").value,
        p_accepting:document.querySelector("#taAccepting").checked
      });
      if(error)alert(error.message);else treatmentDashboard(app,ts,{header,onExit});
    };

    document.querySelector("#createWalkin").onclick=async()=>{
      const nature=document.querySelector("#walkinNature").value.trim()||"Walk-In Medical";
      const note=document.querySelector("#walkinNote").value.trim();
      const {data,error}=await supabase.rpc("treatment_create_walkin_incident",{
        p_treatment_area_id:area.id,
        p_call_type:nature,
        p_priority:"Standard",
        p_notes:note
      });
      if(error)return alert(error.message);
      alert(`Created ${data}.`);
      treatmentDashboard(app,ts,{header,onExit});
    };

    const searchTreatmentIncidents=async()=>{
      const query=document.querySelector("#treatmentIncidentSearch").value.trim();
      const host=document.querySelector("#treatmentIncidentResults");
      host.innerHTML=`<div class="small muted">Searching…</div>`;

      const {data,error}=await supabase.rpc("treatment_search_open_incidents",{
        p_treatment_area_id:area.id,
        p_query:query||null
      });
      if(error){
        host.innerHTML=`<div class="notice error">${esc(error.message)}</div>`;
        return;
      }

      const rows=data||[];
      host.innerHTML=rows.map(row=>{
        const alreadyHere=row.current_treatment_area_id===area.id&&row.current_ems_status==="IN_TREATMENT";
        return `<div class="treatment-search-result">
          <div>
            <strong>${esc(row.incident_number)}</strong> · ${esc(row.call_type)}
            <div class="small muted">${esc(row.priority||"")}${row.landmark?` · ${esc(row.landmark)}`:""}${row.current_ems_status?` · EMS: ${esc(pretty(row.current_ems_status))}`:""}</div>
          </div>
          <button class="btn ${alreadyHere?"secondary":"good"}" data-treatment-receive="${row.incident_id}" ${alreadyHere?"disabled":""}>${alreadyHere?"Already Here":"Mark Received Here"}</button>
        </div>`;
      }).join("")||`<div class="small muted">No open incidents matched that search.</div>`;

      host.querySelectorAll("[data-treatment-receive]").forEach(btn=>btn.onclick=async()=>{
        const row=rows.find(r=>r.incident_id===btn.dataset.treatmentReceive);
        if(!row)return;
        if(!confirm(`Mark ${row.incident_number} as received at ${area.name}?`))return;
        const note=prompt("Optional note:","")||"";
        const {data:result,error:receiveError}=await supabase.rpc("treatment_receive_incident",{
          p_treatment_area_id:area.id,
          p_incident_id:row.incident_id,
          p_note:note||null
        });
        if(receiveError)return alert(receiveError.message);
        if(result==="ALREADY_HERE")alert(`${row.incident_number} is already recorded at ${area.name}.`);
        treatmentDashboard(app,ts,{header,onExit});
      });
    };

    document.querySelector("#treatmentSearchBtn").onclick=searchTreatmentIncidents;
    document.querySelector("#treatmentIncidentSearch").addEventListener("keydown",e=>{
      if(e.key==="Enter")searchTreatmentIncidents();
    });

    document.querySelectorAll("[data-ta-transfer-amb]").forEach(b=>b.onclick=async()=>{
      const id=b.dataset.taTransferAmb;
      const amb=document.querySelector(`#ta-amb-${id}`).value;
      if(!amb)return alert("Choose an ambulance.");
      if(!confirm("Confirm patient handoff to the selected ambulance?"))return;

      const {error}=await supabase.rpc("ems_transfer_custody",{
        p_encounter_id:id,
        p_to_unit_id:amb,
        p_to_treatment_area_id:null,
        p_note:null
      });
      if(error)alert(error.message);else treatmentDashboard(app,ts,{header,onExit});
    });

    document.querySelectorAll("[data-ta-release]").forEach(b=>b.onclick=async()=>{
      const disp=prompt("Operational disposition:","RELEASED_FROM_TREATMENT")||"RELEASED_FROM_TREATMENT";
      const {error}=await supabase.rpc("ems_release_encounter",{
        p_encounter_id:b.dataset.taRelease,
        p_disposition:disp
      });
      if(error)alert(error.message);else treatmentDashboard(app,ts,{header,onExit});
    });

    document.querySelector("#taRefresh").onclick=()=>treatmentDashboard(app,ts,{header,onExit});
    document.querySelector("#taChange").onclick=async()=>{
      await clearTreatmentRealtime();
      await supabase.rpc("treatment_release_area",{p_treatment_session_id:ts.id});
      renderTreatmentAreaFlow(app,{header,onExit});
    };
    document.querySelector("#taLeave").onclick=async()=>{
      await clearTreatmentRealtime();
      await supabase.rpc("treatment_end_session",{p_treatment_session_id:ts.id});
      await supabase.auth.signOut();
      onExit();
    };

    await ensureTreatmentRealtime(app,ts,area,{header,onExit});
  }catch(err){
    console.error("Treatment area dashboard error",err);
    treatmentError(app,header,err.message,onExit);
  }
}
