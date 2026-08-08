import "./style.css";
import L from "leaflet";
import { supabase } from "./supabase.js";
import { renderMapBuilder } from "./mapBuilder.js";
import { pixelToGeo, pixelToLeaflet, leafletToPixel } from "./georef.js";
import { saveOfflineEvent, getOfflineEvent, localW3WForCoordinate } from "./offlineStore.js";

const app=document.querySelector("#app");
const S={
  mode:null,session:null,orgs:[],orgId:null,events:[],eventId:null,event:null,
  departments:[],units:[],incidents:[],pois:[],eventMap:null,map:null,realtime:[],
  fieldSession:null,currentLocation:null,isPlatformAdmin:false
};

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]));
const fmt=iso=>iso?new Date(iso).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"}):"";
const header=(sub="")=>`<div class="topbar"><div class="brand">CommCenter Pro<small>${esc(sub)}</small></div><div class="nav" id="topActions"></div></div>`;

async function init(){
  if("serviceWorker"in navigator)navigator.serviceWorker.register("/service-worker.js").catch(console.warn);
  const {data:{session}}=await supabase.auth.getSession();S.session=session;
  supabase.auth.onAuthStateChange((_event,session)=>{S.session=session;});
  route();
}

async function route(){
  cleanupRealtime();
  if(!S.mode)return landing();
  if(S.mode==="staff"){
    if(!S.session||S.session.user?.is_anonymous)return staffLogin();
    return staffFlow();
  }
  if(S.mode==="field")return fieldFlow();
}

function landing(){
  app.innerHTML=`<div class="shell">${header("Event Operations CAD")}
    <div class="center"><div class="card stack">
      <h1>CommCenter Pro</h1>
      <p class="muted">Multi-department event command, dispatch, mapping, field CAD and reporting.</p>
      <button class="btn block" id="fieldAccess">Field Unit Access</button>
      <button class="btn secondary block" id="staffAccess">Dispatcher / Admin Login</button>
    </div></div></div>`;
  document.querySelector("#fieldAccess").onclick=()=>{S.mode="field";route();};
  document.querySelector("#staffAccess").onclick=()=>{S.mode="staff";route();};
}

function staffLogin(){
  app.innerHTML=`<div class="shell">${header("Command Login")}
    <div class="center"><div class="card stack">
      <h2>Dispatcher / Admin Login</h2>
      <div><label>Email</label><input id="email" type="email" autocomplete="email"></div>
      <div><label>Password</label><input id="password" type="password" autocomplete="current-password"></div>
      <button class="btn" id="login">Sign in</button>
      <button class="btn secondary" id="back">Back</button>
      <div id="loginError" class="small muted"></div>
    </div></div></div>`;
  document.querySelector("#back").onclick=()=>{S.mode=null;route();};
  document.querySelector("#login").onclick=async()=>{
    const {error}=await supabase.auth.signInWithPassword({
      email:document.querySelector("#email").value.trim(),
      password:document.querySelector("#password").value
    });
    if(error)document.querySelector("#loginError").textContent=error.message;
    else route();
  };
}

async function loadStaffContext(){
  const uid=S.session.user.id;
  const [{data:memberships},{data:isPlatformAdmin}]=await Promise.all([
    supabase.from("organization_members")
      .select("organization_id,role,organizations(id,name,slug)")
      .eq("user_id",uid),
    supabase.rpc("is_platform_admin")
  ]);
  S.orgs=memberships||[];
  S.isPlatformAdmin=!!isPlatformAdmin;
}

async function staffFlow(){
  await loadStaffContext();
  if(!S.orgId){
    if(S.orgs.length===1)S.orgId=S.orgs[0].organization_id;
    else return orgPicker();
  }
  const {data}=await supabase.rpc("staff_events_for_org",{p_organization_id:S.orgId});
  S.events=data||[];
  if(!S.eventId)return eventPicker();
  return dispatchPage();
}

function orgPicker(){
  app.innerHTML=`<div class="shell">${header("Select Organization")}<div class="wrap stack">
    <div class="row"><h2>Organizations</h2>${S.isPlatformAdmin?`<button class="btn" id="createOrgBtn">+ Customer Organization</button>`:""}</div>
    ${S.orgs.map(o=>`<button class="choice" data-org="${o.organization_id}">
      <strong>${esc(o.organizations?.name)}</strong><br><span class="muted">${esc(o.role)}</span>
    </button>`).join("")||`<div class="card">No organization membership found.</div>`}
    <button class="btn secondary" id="orgLogout">Sign out</button>
  </div></div>`;
  document.querySelectorAll("[data-org]").forEach(b=>b.onclick=()=>{S.orgId=b.dataset.org;staffFlow();});
  document.querySelector("#orgLogout").onclick=async()=>{await supabase.auth.signOut();S.mode=null;reset();route();};
  if(S.isPlatformAdmin)document.querySelector("#createOrgBtn").onclick=()=>createOrganizationForm();
}

function createOrganizationForm(){
  app.innerHTML=`<div class="shell">${header("Platform Admin · New Customer")}
    <div class="center"><div class="card stack">
      <h2>Create Customer Organization</h2>
      <div><label>Company / organization name</label><input id="orgName" placeholder="Superior Event Management"></div>
      <button class="btn" id="saveOrg">Create Organization</button>
      <button class="btn secondary" id="cancelOrg">Cancel</button>
      <div id="orgErr" class="small muted"></div>
    </div></div></div>`;
  document.querySelector("#cancelOrg").onclick=()=>staffFlow();
  document.querySelector("#saveOrg").onclick=async()=>{
    const {data,error}=await supabase.rpc("platform_create_organization",{p_name:document.querySelector("#orgName").value.trim()});
    if(error)return document.querySelector("#orgErr").textContent=error.message;
    S.orgId=data;
    await staffFlow();
  };
}

function eventPicker(){
  const org=S.orgs.find(o=>o.organization_id===S.orgId);
  app.innerHTML=`<div class="shell">${header(org?.organizations?.name||"Events")}
    <div class="wrap stack">
      <div class="row"><h2>Events</h2><div class="nav">
        <button class="btn" id="newEvent">+ Create Event</button><button class="btn secondary" id="orgSettings">Organization Staff</button><button class="btn secondary" id="changeOrg">Organizations</button><button class="btn secondary" id="logout">Sign out</button>
      </div></div>
      ${S.events.map(e=>`<button class="choice" data-event="${e.id}">
        <strong>${esc(e.name)}</strong><br><span class="muted">${esc(e.event_code)} · ${esc(e.staff_role)}</span>
      </button>`).join("")||`<div class="card">No events yet.</div>`}
    </div></div>`;
  document.querySelector("#logout").onclick=async()=>{await supabase.auth.signOut();S.mode=null;reset();route();};
  document.querySelector("#changeOrg").onclick=()=>{S.orgId=null;S.eventId=null;orgPicker();};
  document.querySelector("#orgSettings").onclick=()=>organizationStaffPage();
  document.querySelector("#newEvent").onclick=()=>newEventForm();
  document.querySelectorAll("[data-event]").forEach(b=>b.onclick=()=>{S.eventId=b.dataset.event;dispatchPage();});
}

function organizationStaffPage(){
  const org=S.orgs.find(o=>o.organization_id===S.orgId);
  app.innerHTML=`<div class="shell">${header(`${esc(org?.organizations?.name||"Organization")} · Staff`)}
    <div class="center"><div class="card stack">
      <p class="muted">This starter can assign an existing Supabase Auth user to this organization. Create the person's account first in Supabase Authentication → Users, then enter that same email here.</p>
      <div><label>User email</label><input id="memberEmail" type="email" placeholder="dispatcher@example.com"></div>
      <div><label>Organization role</label><select id="memberRole">
        <option value="admin">Admin</option><option value="dispatcher">Dispatcher</option><option value="viewer">Viewer</option><option value="owner">Owner</option>
      </select></div>
      <button class="btn" id="addMember">Add / Update Member</button>
      <button class="btn secondary" id="backEvents">Back to Events</button>
      <div id="memberMsg" class="small muted"></div>
    </div></div></div>`;
  document.querySelector("#backEvents").onclick=()=>eventPicker();
  document.querySelector("#addMember").onclick=async()=>{
    const {error}=await supabase.rpc("add_existing_org_member",{
      p_organization_id:S.orgId,
      p_email:document.querySelector("#memberEmail").value.trim(),
      p_role:document.querySelector("#memberRole").value
    });
    document.querySelector("#memberMsg").textContent=error?error.message:"Member added/updated.";
  };
}

function newEventForm(){
  const org=S.orgs.find(o=>o.organization_id===S.orgId);
  app.innerHTML=`<div class="shell">${header(`${org?.organizations?.name||""} · Create Event`)}
    <div class="center"><div class="card stack">
      <div><label>Event name</label><input id="eventName" placeholder="XRoads41 2027"></div>
      <div><label>Event ID / field code</label><input id="eventCode" placeholder="XR41"></div>
      <div><label>4-digit field PIN</label><input id="fieldPin" inputmode="numeric" maxlength="4" placeholder="4821"></div>
      <div><label>Incident prefix</label><input id="prefix" placeholder="XR27"></div>
      <button class="btn" id="createEvent">Create Event</button>
      <button class="btn secondary" id="cancel">Cancel</button>
      <div id="eventErr" class="small muted"></div>
    </div></div></div>`;
  document.querySelector("#cancel").onclick=()=>eventPicker();
  document.querySelector("#createEvent").onclick=async()=>{
    const {data,error}=await supabase.rpc("create_event",{
      p_organization_id:S.orgId,
      p_name:document.querySelector("#eventName").value.trim(),
      p_event_code:document.querySelector("#eventCode").value.trim().toUpperCase(),
      p_pin:document.querySelector("#fieldPin").value.trim(),
      p_incident_prefix:document.querySelector("#prefix").value.trim().toUpperCase()
    });
    if(error)return document.querySelector("#eventErr").textContent=error.message;
    S.eventId=data;
    await eventAdmin();
  };
}

async function loadEventOps(){
  const [{data:event},{data:deps},{data:units},{data:incidents},{data:pois},{data:eventMap}]=await Promise.all([
    supabase.from("events").select("*").eq("id",S.eventId).single(),
    supabase.from("event_departments").select("*").eq("event_id",S.eventId).order("sort_order"),
    supabase.from("units").select("*,event_departments(name,short_name)").eq("event_id",S.eventId).eq("active",true).order("name"),
    supabase.from("incidents")
      .select("*,incident_departments(department_id,event_departments(name,short_name)),incident_units(unit_id,cleared_at,units(name))")
      .eq("event_id",S.eventId).neq("status","CLOSED").order("created_at",{ascending:false}),
    supabase.from("event_pois").select("*,poi_aliases(alias)").eq("event_id",S.eventId).eq("active",true).order("name"),
    supabase.from("event_maps").select("*").eq("event_id",S.eventId).maybeSingle()
  ]);
  S.event=event;S.departments=deps||[];S.units=units||[];S.incidents=incidents||[];S.pois=pois||[];S.eventMap=eventMap||null;
}

async function storageSigned(path,seconds=3600){
  if(!path)return null;
  const {data,error}=await supabase.storage.from("event-assets").createSignedUrl(path,seconds);
  if(error)throw error;
  return data.signedUrl;
}

/* ---------------- DISPATCH ---------------- */

async function dispatchPage(){
  await loadEventOps();
  app.innerHTML=`<div class="shell">${header(`${esc(S.event?.name||"Event")} · Unified Dispatch`)}
    <div class="cad-grid">
      <aside class="panel left">
        <button class="btn block" id="newIncident">+ New Incident</button>
        <div class="section-title">Active incidents</div><div id="incidentList">${incidentList()}</div>
      </aside>
      <div class="map-wrap"><div id="map"></div></div>
      <aside class="panel right">
        <div class="row"><div class="section-title">Units</div></div>
        <div id="unitList">${unitList()}</div>
        <div class="section-title">Incident detail</div><div id="detail" class="muted">Select an incident or click the map.</div>
      </aside>
    </div></div>`;
  document.querySelector("#topActions").innerHTML=`
    <button class="btn secondary" id="adminBtn">Event Admin</button>
    <button class="btn secondary" id="reportsBtn">Reports</button>
    <button class="btn secondary" id="eventsBtn">Events</button>
    <button class="btn secondary" id="logoutBtn">Sign out</button>`;
  document.querySelector("#adminBtn").onclick=()=>eventAdmin();
  document.querySelector("#reportsBtn").onclick=()=>reportsPage();
  document.querySelector("#eventsBtn").onclick=()=>{S.eventId=null;staffFlow();};
  document.querySelector("#logoutBtn").onclick=async()=>{await supabase.auth.signOut();S.mode=null;reset();route();};
  document.querySelector("#newIncident").onclick=()=>incidentForm(null);
  bindIncidentClicks();
  await setupDispatchMap();
  subscribeDispatch();
}

function incidentList(){
  return S.incidents.map(i=>{
    const deps=(i.incident_departments||[]).map(d=>d.event_departments?.short_name||d.event_departments?.name).filter(Boolean).join("/");
    return `<div class="incident" data-incident="${i.id}">
      <div class="row"><strong>${esc(i.incident_number)}</strong><span class="badge">${esc(i.priority)}</span></div>
      <div>${esc(i.call_type)}</div><div class="small muted">${esc(deps)} · ${esc(i.landmark||i.w3w||"Mapped")}</div>
    </div>`;
  }).join("")||`<div class="small muted">No active incidents.</div>`;
}
function unitList(){
  return S.units.map(u=>`<div class="unit"><div class="row">
    <strong>${esc(u.event_departments?.short_name||"")} · ${esc(u.name)}</strong>
    <span class="badge status-${esc(u.status)}">${esc(u.status.replaceAll("_"," "))}</span>
  </div></div>`).join("")||`<div class="small muted">No units configured.</div>`;
}
function bindIncidentClicks(){
  document.querySelectorAll("[data-incident]").forEach(b=>b.onclick=()=>selectIncident(b.dataset.incident));
}
function selectIncident(id){
  const i=S.incidents.find(x=>x.id===id);if(!i)return;
  const assigned=(i.incident_units||[]).filter(x=>!x.cleared_at).map(x=>x.units?.name).filter(Boolean);
  document.querySelector("#detail").innerHTML=`<div class="card stack">
    <div class="row"><strong>${esc(i.incident_number)}</strong><span class="badge">${esc(i.priority)}</span></div>
    <strong>${esc(i.call_type)}</strong>
    <div>${i.w3w?`<strong>///${esc(i.w3w)}</strong><br>`:""}${esc(i.landmark||"")}<br>
    <span class="small mono">${Number(i.latitude).toFixed(6)}, ${Number(i.longitude).toFixed(6)}</span></div>
    <div>${esc(i.notes||"")}</div>
    <div><strong>Assigned:</strong> ${esc(assigned.join(", ")||"None")}</div>
    <div><label>Assign unit</label><select id="assignUnit"><option value="">Choose unit</option>
      ${S.units.map(u=>`<option value="${u.id}">${esc(u.event_departments?.short_name||"")} · ${esc(u.name)} · ${esc(u.status)}</option>`).join("")}
    </select></div>
    <button class="btn" id="dispatchUnit">Dispatch Unit</button>
    <button class="btn secondary" id="closeIncident">Close Incident</button>
  </div>`;
  document.querySelector("#dispatchUnit").onclick=async()=>{
    const unitId=document.querySelector("#assignUnit").value;if(!unitId)return;
    const {error}=await supabase.rpc("assign_unit",{p_incident_id:i.id,p_unit_id:unitId});
    if(error)alert(error.message);else dispatchPage();
  };
  document.querySelector("#closeIncident").onclick=async()=>{
    const disposition=prompt("Disposition:","Complete");
    const {error}=await supabase.rpc("close_incident",{p_incident_id:i.id,p_disposition:disposition});
    if(error)alert(error.message);else dispatchPage();
  };
  if(S.map&&i.map_x!=null&&i.map_y!=null&&S.eventMap){
    S.map.setView(pixelToLeaflet(i.map_x,i.map_y,S.eventMap.image_height),Math.max(S.map.getZoom(),0));
  }
}

async function setupDispatchMap(){
  if(!S.eventMap?.rendered_image_path || S.eventMap.status!=="published"){
    S.map=L.map("map",{crs:L.CRS.Simple,attributionControl:false}).setView([0,0],0);
    L.popup().setLatLng([0,0]).setContent("No published event map yet. Open Event Admin → Map Builder.").openOn(S.map);
    return;
  }
  const url=await storageSigned(S.eventMap.rendered_image_path);
  S.map=L.map("map",{crs:L.CRS.Simple,minZoom:-4,maxZoom:5,zoomSnap:.25,attributionControl:false});
  const bounds=[[0,0],[S.eventMap.image_height,S.eventMap.image_width]];
  L.imageOverlay(url,bounds).addTo(S.map);S.map.fitBounds(bounds);

  for(const p of S.pois){
    L.marker(pixelToLeaflet(p.map_x,p.map_y,S.eventMap.image_height)).addTo(S.map)
      .bindTooltip(`${p.name}${p.w3w?` · ///${p.w3w}`:""}`);
  }
  for(const i of S.incidents){
    if(i.map_x!=null&&i.map_y!=null)L.circleMarker(pixelToLeaflet(i.map_x,i.map_y,S.eventMap.image_height),{radius:8}).addTo(S.map).bindTooltip(i.incident_number);
  }
  if(S.eventMap.georef_coefficients){
    S.map.on("click",async e=>{
      const px=leafletToPixel(e.latlng,S.eventMap.image_height);
      const geo=pixelToGeo(px.x,px.y,S.eventMap.georef_coefficients);
      const {data:words}=await supabase.rpc("w3w_for_coordinate",{p_event_id:S.eventId,p_lat:geo.lat,p_lon:geo.lon});
      S.currentLocation={map_x:px.x,map_y:px.y,latitude:geo.lat,longitude:geo.lon,w3w:words||null,poi_id:null,landmark:""};
      L.popup().setLatLng(e.latlng).setContent(`<strong>${words?`///${esc(words)}`:"Selected location"}</strong><br>${geo.lat.toFixed(6)}, ${geo.lon.toFixed(6)}<br><br><button id="createAtPoint">Create incident here</button>`).openOn(S.map);
      setTimeout(()=>document.querySelector("#createAtPoint")?.addEventListener("click",()=>incidentForm(S.currentLocation)),0);
    });
  }
}

function incidentForm(loc){
  const detail=document.querySelector("#detail");
  detail.innerHTML=`<div class="card stack"><strong>New Incident</strong>
    <div><label>Use a POI</label><select id="poiSelect"><option value="">-- Map location / none --</option>
      ${S.pois.map(p=>`<option value="${p.id}">${esc(p.name)}${p.w3w?` · ///${esc(p.w3w)}`:""}</option>`).join("")}
    </select></div>
    <div><label>Departments</label>${S.departments.map(d=>`<label style="font-weight:500"><input type="checkbox" name="dept" value="${d.id}"> ${esc(d.name)}</label>`).join("")}</div>
    <div><label>Call type</label><input id="callType" placeholder="Medical, disturbance, power issue…"></div>
    <div><label>Priority</label><select id="priority"><option>Standard</option><option>Urgent</option><option>Critical</option></select></div>
    <div><label>Location description</label><input id="landmark" value="${esc(loc?.landmark||"")}"></div>
    <div><label>Dispatch notes</label><textarea id="notes" rows="4"></textarea></div>
    <div id="locSummary" class="small muted">${loc?`${loc.w3w?`///${esc(loc.w3w)} · `:""}${Number(loc.latitude).toFixed(6)}, ${Number(loc.longitude).toFixed(6)}`:"Choose a POI or click the map first."}</div>
    <button class="btn" id="saveIncident">Create Incident</button>
  </div>`;

  let chosen=loc?{...loc}:null;
  document.querySelector("#poiSelect").onchange=()=>{
    const p=S.pois.find(x=>x.id===document.querySelector("#poiSelect").value);
    if(!p)return;
    chosen={poi_id:p.id,map_x:p.map_x,map_y:p.map_y,latitude:p.latitude,longitude:p.longitude,w3w:p.w3w,landmark:p.name};
    document.querySelector("#landmark").value=p.name;
    document.querySelector("#locSummary").textContent=`${p.w3w?`///${p.w3w} · `:""}${Number(p.latitude).toFixed(6)}, ${Number(p.longitude).toFixed(6)}`;
  };
  document.querySelector("#saveIncident").onclick=async()=>{
    if(!chosen)return alert("Choose a POI or click the map to set the incident location.");
    const deps=[...document.querySelectorAll('input[name="dept"]:checked')].map(x=>x.value);
    if(!deps.length)return alert("Choose at least one department.");
    const {data,error}=await supabase.rpc("create_incident",{
      p_event_id:S.eventId,p_department_ids:deps,p_call_type:document.querySelector("#callType").value.trim()||"Other",
      p_priority:document.querySelector("#priority").value,p_latitude:chosen.latitude,p_longitude:chosen.longitude,
      p_map_x:chosen.map_x,p_map_y:chosen.map_y,p_w3w:chosen.w3w,
      p_landmark:document.querySelector("#landmark").value.trim(),p_notes:document.querySelector("#notes").value.trim(),
      p_poi_id:chosen.poi_id||null
    });
    if(error)return alert(error.message);
    await dispatchPage();if(data)setTimeout(()=>selectIncident(data),50);
  };
}

/* ---------------- EVENT ADMIN ---------------- */

async function eventAdmin(){
  await loadEventOps();
  app.innerHTML=`<div class="shell">${header(`${esc(S.event?.name||"Event")} · Event Admin`)}
    <div class="admin-layout">
      <aside class="admin-menu">
        <button class="active" id="setupTab">Setup</button>
        <button id="mapTab">Map Builder</button>
        <button id="backDispatch">Back to CAD</button>
      </aside>
      <main class="admin-content"><div id="adminContent"></div></main>
    </div></div>`;
  document.querySelector("#backDispatch").onclick=()=>dispatchPage();
  document.querySelector("#mapTab").onclick=()=>renderMapBuilder(app,S.eventId,()=>eventAdmin());
  document.querySelector("#setupTab").onclick=()=>renderEventSetup();
  renderEventSetup();
}

function renderEventSetup(){
  document.querySelector("#adminContent").innerHTML=`<div class="stack">
    <div class="card">
      <h2>Field Access</h2>
      <div class="grid2">
        <div><label>Event ID</label><input value="${esc(S.event.event_code)}" disabled></div>
        <div><label>New 4-digit PIN</label><input id="newPin" maxlength="4" inputmode="numeric" placeholder="4821"></div>
      </div>
      <label style="margin-top:10px"><input id="accessEnabled" type="checkbox" ${S.event.field_access_enabled?"checked":""}> Field access enabled</label>
      <button class="btn" id="savePin">Save Field Access</button>
      <div id="pinMsg" class="small muted"></div>
    </div>

    <div class="card">
      <h2>Departments</h2>
      <div id="deptList">${S.departments.map(d=>`<div class="poi-row"><strong>${esc(d.name)}</strong> <span class="muted">${esc(d.short_name||"")}</span><br><span class="small mono">${esc(JSON.stringify(d.status_profile))}</span></div>`).join("")}</div>
      <div class="grid3">
        <input id="deptName" placeholder="Police">
        <input id="deptShort" placeholder="PD">
        <input id="deptStatuses" placeholder="AVAILABLE,RESPONDING,ON_SCENE,CLEAR">
      </div>
      <button class="btn" id="addDept">Add Department</button>
    </div>

    <div class="card">
      <h2>Units</h2>
      <div id="adminUnits">${unitList()}</div>
      <div class="grid2">
        <select id="unitDept"><option value="">Department</option>${S.departments.map(d=>`<option value="${d.id}">${esc(d.name)}</option>`).join("")}</select>
        <input id="unitName" placeholder="Medic 1">
      </div>
      <button class="btn" id="addUnit">Add Unit</button>
    </div>

    <div class="card">
      <h2>Event Map</h2>
      <p>${S.eventMap?.rendered_image_path?`Map uploaded · status: <strong>${esc(S.eventMap.status)}</strong>`:"No map uploaded yet."}</p>
      <button class="btn" id="openMapBuilder">Open Map Builder</button>
    </div>
  </div>`;

  document.querySelector("#savePin").onclick=async()=>{
    const pin=document.querySelector("#newPin").value.trim();
    const enabled=document.querySelector("#accessEnabled").checked;
    if(pin&& !/^\d{4}$/.test(pin))return alert("PIN must be exactly 4 digits.");
    const {error}=await supabase.rpc("set_event_field_access",{p_event_id:S.eventId,p_pin:pin||null,p_enabled:enabled});
    document.querySelector("#pinMsg").textContent=error?error.message:"Saved.";
    if(!error){await loadEventOps();renderEventSetup();}
  };
  document.querySelector("#addDept").onclick=async()=>{
    const statuses=document.querySelector("#deptStatuses").value.split(",").map(x=>x.trim().toUpperCase()).filter(Boolean);
    const {error}=await supabase.from("event_departments").insert({
      event_id:S.eventId,name:document.querySelector("#deptName").value.trim(),
      short_name:document.querySelector("#deptShort").value.trim().toUpperCase(),
      status_profile:statuses.length?statuses:["AVAILABLE","RESPONDING","ON_SCENE","CLEAR","OUT_OF_SERVICE"]
    });
    if(error)alert(error.message);else{await loadEventOps();renderEventSetup();}
  };
  document.querySelector("#addUnit").onclick=async()=>{
    const {error}=await supabase.from("units").insert({
      event_id:S.eventId,department_id:document.querySelector("#unitDept").value,name:document.querySelector("#unitName").value.trim()
    });
    if(error)alert(error.message);else{await loadEventOps();renderEventSetup();}
  };
  document.querySelector("#openMapBuilder").onclick=()=>renderMapBuilder(app,S.eventId,()=>eventAdmin());
}

/* ---------------- REPORTS ---------------- */

async function reportsPage(){
  const {data,error}=await supabase.from("dispatch_log").select("*").eq("event_id",S.eventId).order("received_time");
  if(error)return alert(error.message);
  app.innerHTML=`<div class="shell">${header(`${esc(S.event?.name||"Event")} · Reports`)}
    <div class="wrap stack">
      <div class="row"><h2>Dispatch Log</h2><div class="nav"><button class="btn secondary" id="backCad">Back to CAD</button><button class="btn" id="downloadCsv">Download CSV</button></div></div>
      <div class="table-wrap"><table><thead><tr>
        <th>Incident</th><th>Received</th><th>Departments</th><th>Nature</th><th>Priority</th><th>Location</th><th>W3W</th><th>Units</th><th>En Route</th><th>On Scene</th><th>Disposition</th><th>Clear</th>
      </tr></thead><tbody>${(data||[]).map(r=>`<tr>
        <td>${esc(r.incident_number)}</td><td>${fmt(r.received_time)}</td><td>${esc(r.departments||"")}</td><td>${esc(r.call_type)}</td><td>${esc(r.priority)}</td>
        <td>${esc(r.landmark||"")}</td><td>${r.w3w?`///${esc(r.w3w)}`:""}</td><td>${esc(r.units||"")}</td><td>${fmt(r.first_enroute)}</td><td>${fmt(r.first_onscene)}</td><td>${esc(r.disposition||"")}</td><td>${fmt(r.last_clear||r.closed_at)}</td>
      </tr>`).join("")}</tbody></table></div>
    </div></div>`;
  document.querySelector("#backCad").onclick=()=>dispatchPage();
  document.querySelector("#downloadCsv").onclick=()=>downloadCsv(data||[]);
}
function downloadCsv(rows){
  const cols=["incident_number","received_time","departments","call_type","priority","landmark","w3w","latitude","longitude","units","first_enroute","first_onscene","first_transporting","last_clear","disposition","closed_at"];
  const q=v=>`"${String(v??"").replaceAll('"','""')}"`;
  const csv=[cols.join(","),...rows.map(r=>cols.map(c=>q(r[c])).join(","))].join("\n");
  const a=document.createElement("a");a.href=URL.createObjectURL(new Blob([csv],{type:"text/csv;charset=utf-8"}));a.download=`${S.event?.event_code||"event"}-dispatch-log.csv`;a.click();URL.revokeObjectURL(a.href);
}

/* ---------------- FIELD ---------------- */

async function fieldFlow(){
  if(!S.session||!S.session.user?.is_anonymous){
    const {error}=await supabase.auth.signInAnonymously();
    if(error)return fieldError(error.message);
    S.session=(await supabase.auth.getSession()).data.session;
  }
  const {data:fs}=await supabase.from("field_sessions")
    .select("*,events(name,event_code),units(name,status,department_id,event_departments(name,short_name,status_profile))")
    .eq("auth_user_id",S.session.user.id).eq("active",true).order("started_at",{ascending:false}).limit(1).maybeSingle();
  if(!fs)return fieldJoin();
  S.fieldSession=fs;S.eventId=fs.event_id;
  if(!fs.unit_id)return fieldUnitPicker();
  return fieldUnitCad();
}
function fieldError(message){
  app.innerHTML=`<div class="center"><div class="card stack"><h2>Field Access Error</h2><div class="notice error">${esc(message)}</div><button class="btn" id="home">Back</button></div></div>`;
  document.querySelector("#home").onclick=()=>{S.mode=null;route();};
}
function fieldJoin(){
  app.innerHTML=`<div class="shell">${header("Field Unit Access")}<div class="center"><div class="card stack">
    <h2>Join Event</h2>
    <div><label>Event ID</label><input id="fieldEventCode" placeholder="XR41"></div>
    <div><label>4-digit access code</label><input id="fieldPin" inputmode="numeric" maxlength="4" placeholder="••••"></div>
    <div><label>Operator name (optional)</label><input id="operatorName" placeholder="First name / callsign"></div>
    <button class="btn" id="joinEvent">Continue</button><button class="btn secondary" id="home">Back</button><div id="fieldErr" class="small muted"></div>
  </div></div></div>`;
  document.querySelector("#home").onclick=async()=>{await supabase.auth.signOut();S.mode=null;route();};
  document.querySelector("#joinEvent").onclick=async()=>{
    const {data,error}=await supabase.rpc("field_enter_event",{
      p_event_code:document.querySelector("#fieldEventCode").value.trim().toUpperCase(),
      p_pin:document.querySelector("#fieldPin").value.trim(),
      p_operator_name:document.querySelector("#operatorName").value.trim()
    });
    if(error)return document.querySelector("#fieldErr").textContent=error.message;
    S.fieldSession=data;S.eventId=data.event_id;fieldUnitPicker();
  };
}
async function fieldUnitPicker(){
  const [{data:event},{data:deps},{data:units}]=await Promise.all([
    supabase.from("events").select("name").eq("id",S.eventId).single(),
    supabase.from("event_departments").select("*").eq("event_id",S.eventId).eq("active",true).order("sort_order"),
    supabase.from("units").select("*,event_departments(name,short_name)").eq("event_id",S.eventId).eq("active",true).order("name")
  ]);
  app.innerHTML=`<div class="shell">${header(`${esc(event?.name||"Event")} · Select Unit`)}<div class="wrap">
    ${(deps||[]).map(d=>`<div class="section-title">${esc(d.name)}</div><div class="grid2">
      ${(units||[]).filter(u=>u.department_id===d.id).map(u=>`<button class="choice" data-unit="${u.id}"><strong>${esc(u.name)}</strong><br><span class="badge status-${esc(u.status)}">${esc(u.status.replaceAll("_"," "))}</span></button>`).join("")}
    </div>`).join("")}
    <button class="btn secondary" id="leaveEvent" style="margin-top:18px">Leave Event</button>
  </div></div>`;
  document.querySelectorAll("[data-unit]").forEach(b=>b.onclick=async()=>{
    const {error}=await supabase.rpc("field_claim_unit",{p_field_session_id:S.fieldSession.id,p_unit_id:b.dataset.unit});
    if(error)alert(error.message);else fieldUnitCad();
  });
  document.querySelector("#leaveEvent").onclick=leaveField;
}
async function fieldUnitCad(){
  const {data:fs,error}=await supabase.from("field_sessions")
    .select("*,events(name),units(name,status,event_id,event_departments(name,status_profile))")
    .eq("auth_user_id",S.session.user.id).eq("active",true).order("started_at",{ascending:false}).limit(1).single();
  if(error)return fieldJoin();
  S.fieldSession=fs;S.eventId=fs.event_id;
  const {data:a}=await supabase.from("incident_units").select("*,incidents(*)")
    .eq("unit_id",fs.unit_id).is("cleared_at",null).order("assigned_at",{ascending:false}).limit(1).maybeSingle();
  const incident=a?.incidents;
  const statuses=fs.units?.event_departments?.status_profile||["AVAILABLE","RESPONDING","ON_SCENE","CLEAR"];

  app.innerHTML=`<div class="shell">${header(`${esc(fs.events?.name||"")} · ${esc(fs.units?.event_departments?.name||"")}`)}
    <div class="field-shell stack">
      <div class="card"><div class="small muted">Your unit</div><div class="big">${esc(fs.units?.name)}</div><span class="badge status-${esc(fs.units?.status)}">${esc(fs.units?.status?.replaceAll("_"," "))}</span></div>
      ${incident?`<div class="card assignment"><div class="row"><strong>${esc(incident.incident_number)}</strong><span class="badge">${esc(incident.priority)}</span></div>
        <h2>${esc(incident.call_type)}</h2><p>${incident.w3w?`<strong>///${esc(incident.w3w)}</strong><br>`:""}${esc(incident.landmark||"")}<br>
        <span class="small mono">${Number(incident.latitude).toFixed(6)}, ${Number(incident.longitude).toFixed(6)}</span></p><p>${esc(incident.notes||"")}</p>
        <button class="btn secondary block" id="viewFieldMap">View on Event Map</button>
        <div id="fieldMapHolder"></div>
      </div>`:`<div class="card"><strong>No current assignment</strong><p class="muted">Remain available for dispatch.</p></div>`}
      <div class="status-buttons">${statuses.map(s=>`<button class="btn ${["AVAILABLE","CLEAR","COMPLETE"].includes(s)?"good":""}" data-status="${esc(s)}">${esc(s.replaceAll("_"," "))}</button>`).join("")}</div>
      <div class="notice ${navigator.onLine?"ok":""}">${navigator.onLine?"Connected":"Offline — CAD changes cannot reach dispatch until connectivity returns."}</div>
      <button class="btn secondary" id="downloadOffline">Download Event Map + W3W for Offline Use</button>
      <div id="offlineStatus" class="small muted"></div>
      <button class="btn secondary" id="changeUnit">Change Unit</button><button class="btn secondary" id="leaveEvent">Leave Event</button>
    </div></div>`;
  document.querySelectorAll("[data-status]").forEach(b=>b.onclick=async()=>{
    const {error}=await supabase.rpc("field_set_unit_status",{p_unit_id:fs.unit_id,p_status:b.dataset.status,p_incident_id:incident?.id||null,p_client_time:new Date().toISOString()});
    if(error)alert(error.message);else fieldUnitCad();
  });
  document.querySelector("#downloadOffline").onclick=()=>downloadOfflineEventData();
  getOfflineEvent(S.eventId).then(x=>{if(x)document.querySelector("#offlineStatus").textContent=`Offline package saved ${new Date(x.savedAt).toLocaleString()}`;}).catch(()=>{});
  document.querySelector("#changeUnit").onclick=async()=>{await supabase.rpc("field_release_unit",{p_field_session_id:fs.id});fieldUnitPicker();};
  document.querySelector("#leaveEvent").onclick=leaveField;
  if(incident)document.querySelector("#viewFieldMap").onclick=()=>showFieldMap(incident);
  subscribeField(fs.unit_id);
}
async function downloadOfflineEventData(){
  const status=document.querySelector("#offlineStatus");
  try{
    status.textContent="Downloading event package…";
    const [{data:m},{data:pois}]=await Promise.all([
      supabase.from("event_maps").select("*").eq("event_id",S.eventId).maybeSingle(),
      supabase.from("event_pois").select("id,name,category,w3w,latitude,longitude,map_x,map_y,notes").eq("event_id",S.eventId).eq("active",true)
    ]);
    if(!m?.rendered_image_path || m.status!=="published")throw new Error("No published event map.");
    const {data:mapBlob,error:mapErr}=await supabase.storage.from("event-assets").download(m.rendered_image_path);
    if(mapErr)throw mapErr;

    let w3w=[];
    if(m.offline_w3w_path){
      const {data:w3wBlob,error:wErr}=await supabase.storage.from("event-assets").download(m.offline_w3w_path);
      if(wErr)throw wErr;
      w3w=JSON.parse(await w3wBlob.text());
    }

    await saveOfflineEvent({
      eventId:S.eventId,
      savedAt:new Date().toISOString(),
      mapMeta:m,
      mapBlob,
      pois:pois||[],
      w3w
    });
    status.textContent=`Saved offline: map + ${(w3w||[]).length.toLocaleString()} W3W squares.`;
  }catch(err){
    status.textContent=`Offline download failed: ${err.message}`;
  }
}

async function showFieldMap(incident){
  const holder=document.querySelector("#fieldMapHolder");
  holder.innerHTML=`<div id="fieldMap" style="height:420px;margin-top:10px;border-radius:10px;overflow:hidden"></div><div id="fieldMapReadout" class="small muted" style="margin-top:6px"></div>`;

  let m=null,url=null,w3wRows=[];
  try{
    if(navigator.onLine){
      const {data}=await supabase.from("event_maps").select("*").eq("event_id",S.eventId).maybeSingle();
      if(data?.rendered_image_path && data.status==="published"){
        m=data;
        url=await storageSigned(m.rendered_image_path);
      }
    }
  }catch{}

  const offline=await getOfflineEvent(S.eventId).catch(()=>null);
  if(!m && offline){
    m=offline.mapMeta;
    url=URL.createObjectURL(offline.mapBlob);
    w3wRows=offline.w3w||[];
  }else if(offline){
    w3wRows=offline.w3w||[];
  }

  if(!m||!url)return alert("No published event map is available. Download it for offline use while connected.");

  const map=L.map("fieldMap",{crs:L.CRS.Simple,minZoom:-4,maxZoom:5,attributionControl:false});
  L.imageOverlay(url,[[0,0],[m.image_height,m.image_width]]).addTo(map);

  if(incident.map_x!=null&&incident.map_y!=null){
    const pt=pixelToLeaflet(incident.map_x,incident.map_y,m.image_height);
    L.marker(pt).addTo(map).bindPopup(`${esc(incident.incident_number)}<br>${esc(incident.landmark||"")}`).openPopup();
    map.setView(pt,0);
  }else map.fitBounds([[0,0],[m.image_height,m.image_width]]);

  if(m.georef_coefficients){
    map.on("click",async e=>{
      const px=leafletToPixel(e.latlng,m.image_height);
      const geo=pixelToGeo(px.x,px.y,m.georef_coefficients);
      let words=localW3WForCoordinate(w3wRows,geo.lat,geo.lon);
      if(!words && navigator.onLine){
        try{
          const {data}=await supabase.rpc("w3w_for_coordinate",{p_event_id:S.eventId,p_lat:geo.lat,p_lon:geo.lon});
          words=data||null;
        }catch{}
      }
      document.querySelector("#fieldMapReadout").textContent=`${words?`///${words} · `:""}${geo.lat.toFixed(6)}, ${geo.lon.toFixed(6)}`;
    });
  }
}

async function leaveField(){
  if(S.fieldSession?.id)await supabase.rpc("field_end_session",{p_field_session_id:S.fieldSession.id});
  await supabase.auth.signOut();S.mode=null;reset();route();
}

/* ---------------- REALTIME / RESET ---------------- */

function subscribeDispatch(){
  const ch=supabase.channel(`event-${S.eventId}`)
    .on("postgres_changes",{event:"*",schema:"public",table:"units",filter:`event_id=eq.${S.eventId}`},()=>dispatchPage())
    .on("postgres_changes",{event:"*",schema:"public",table:"incidents",filter:`event_id=eq.${S.eventId}`},()=>dispatchPage())
    .on("postgres_changes",{event:"*",schema:"public",table:"incident_units"},()=>dispatchPage())
    .subscribe();
  S.realtime.push(ch);
}
function subscribeField(unitId){
  const ch=supabase.channel(`unit-${unitId}`)
    .on("postgres_changes",{event:"*",schema:"public",table:"units",filter:`id=eq.${unitId}`},()=>fieldUnitCad())
    .on("postgres_changes",{event:"*",schema:"public",table:"incident_units",filter:`unit_id=eq.${unitId}`},()=>fieldUnitCad())
    .subscribe();
  S.realtime.push(ch);
}
function cleanupRealtime(){
  S.realtime.forEach(ch=>supabase.removeChannel(ch));S.realtime=[];
  if(S.map){try{S.map.remove()}catch{}}S.map=null;
}
function reset(){S.orgId=null;S.eventId=null;S.event=null;S.fieldSession=null;}

init();
