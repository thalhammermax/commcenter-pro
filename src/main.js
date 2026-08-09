import "./style.css";
import L from "leaflet";
import { supabase } from "./supabase.js";
import { renderMapBuilder } from "./mapBuilder.js";
import { pixelToGeo, pixelToLeaflet, leafletToPixel } from "./georef.js";
import { saveOfflineEvent, getOfflineEvent, localW3WForCoordinate } from "./offlineStore.js";
import { renderEmsOps, renderEmsAdmin, renderTreatmentAreaFlow, loadFieldEmsState, fieldEmsPanelHtml, bindFieldEmsPanel } from "./ems.js";
import { loadVenueChoices, applyVenueVersionToEvent, saveEventToVenueLibrary, renderVenueLibrary } from "./venueLibrary.js";

const app=document.querySelector("#app");
const S={
  mode:null,session:null,orgs:[],orgId:null,events:[],eventId:null,event:null,
  departments:[],units:[],incidents:[],pois:[],eventMap:null,mapLayers:[],zones:[],accessPoints:[],accessNodes:[],activeMapLayerId:null,map:null,realtime:[],
  fieldSession:null,currentLocation:null,isPlatformAdmin:false,callTimerInterval:null
};

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]));
const fmt=iso=>iso?new Date(iso).toLocaleTimeString([],{hour:"2-digit",minute:"2-digit"}):"";
const header=(sub="")=>`<div class="topbar"><div class="brand">CommCenter Pro<small>${esc(sub)}</small></div><div class="nav" id="topActions"></div></div>`;

function formatElapsed(startIso){
  const start=new Date(startIso).getTime();
  if(!Number.isFinite(start))return "--:--";
  const total=Math.max(0,Math.floor((Date.now()-start)/1000));
  const days=Math.floor(total/86400);
  const hours=Math.floor((total%86400)/3600);
  const minutes=Math.floor((total%3600)/60);
  const seconds=total%60;
  const pad=n=>String(n).padStart(2,"0");
  if(days>0)return `${days}d ${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;
  if(hours>0)return `${hours}:${pad(minutes)}:${pad(seconds)}`;
  return `${pad(minutes)}:${pad(seconds)}`;
}

function updateCallTimers(){
  document.querySelectorAll("[data-call-start]").forEach(el=>{
    el.textContent=formatElapsed(el.dataset.callStart);
  });
}

function ensureCallTimerTicker(){
  updateCallTimers();
  if(S.callTimerInterval)return;
  S.callTimerInterval=setInterval(updateCallTimers,1000);
}


const DEPARTMENT_STATUS_CATALOG=[
  {value:"AVAILABLE",label:"Available"},
  {value:"RESPONDING",label:"Responding"},
  {value:"EN_ROUTE",label:"En Route"},
  {value:"ON_SCENE",label:"On Scene"},
  {value:"WORKING",label:"Working"},
  {value:"TRANSPORTING",label:"Transporting"},
  {value:"AT_HOSPITAL",label:"At Hospital"},
  {value:"RETURNING",label:"Returning"},
  {value:"CLEAR",label:"Clear"},
  {value:"COMPLETE",label:"Complete"},
  {value:"OUT_OF_SERVICE",label:"Out of Service"}
];

const DEFAULT_DEPARTMENT_STATUSES=[
  "AVAILABLE",
  "RESPONDING",
  "ON_SCENE",
  "CLEAR",
  "OUT_OF_SERVICE"
];

function statusLabel(value){
  return DEPARTMENT_STATUS_CATALOG.find(s=>s.value===value)?.label || String(value||"").replaceAll("_"," ");
}

function departmentStatusPicker(name,selected=DEFAULT_DEPARTMENT_STATUSES){
  const chosen=new Set(Array.isArray(selected)?selected:[]);
  return `<div class="department-status-picker">
    ${DEPARTMENT_STATUS_CATALOG.map(status=>`
      <label class="status-select-option">
        <input type="checkbox" name="${esc(name)}" value="${status.value}" ${chosen.has(status.value)?"checked":""}>
        <span>${esc(status.label)}</span>
      </label>
    `).join("")}
  </div>`;
}

function selectedDepartmentStatuses(name){
  return [...document.querySelectorAll(`input[name="${name}"]:checked`)].map(el=>el.value);
}

const NAV_STATE_KEY="commcenter-pro-navigation-v1";

function saveNavigationState(){
  try{
    localStorage.setItem(NAV_STATE_KEY,JSON.stringify({
      mode:S.mode,
      orgId:S.orgId,
      eventId:S.eventId,
      activeMapLayerId:S.activeMapLayerId
    }));
  }catch{}
}

function restoreNavigationState(){
  try{
    const raw=localStorage.getItem(NAV_STATE_KEY);
    if(!raw)return;
    const saved=JSON.parse(raw);
    S.mode=saved.mode||null;
    S.orgId=saved.orgId||null;
    S.eventId=saved.eventId||null;
    S.activeMapLayerId=saved.activeMapLayerId||null;
  }catch{}
}

function clearNavigationState(){
  try{localStorage.removeItem(NAV_STATE_KEY);}catch{}
}

async function init(){
  if("serviceWorker"in navigator)navigator.serviceWorker.register("/service-worker.js").catch(console.warn);
  const {data:{session}}=await supabase.auth.getSession();S.session=session;
  restoreNavigationState();
  supabase.auth.onAuthStateChange((_event,session)=>{
    S.session=session;
    if(!session){
      S.mode=null;
      reset();
      clearNavigationState();
    }
  });
  route();
}

async function route(){
  cleanupRealtime();
  saveNavigationState();
  if(!S.mode)return landing();
  if(S.mode==="staff"){
    if(!S.session||S.session.user?.is_anonymous)return staffLogin();
    return staffFlow();
  }
  if(S.mode==="field")return fieldFlow();
  if(S.mode==="treatment")return renderTreatmentAreaFlow(app,{
    header,
    onExit:()=>{S.mode=null;reset();clearNavigationState();route();}
  });
}

function landing(){
  app.innerHTML=`<div class="shell">${header("Event Operations CAD")}
    <div class="center"><div class="card stack">
      <h1>CommCenter Pro</h1>
      <p class="muted">Multi-department event command, dispatch, mapping, field CAD and reporting.</p>
      <button class="btn block" id="fieldAccess">Field Unit Access</button>
      <button class="btn block" id="treatmentAccess">Treatment Area Station</button>
      <button class="btn secondary block" id="staffAccess">Dispatcher / Admin Login</button>
    </div></div></div>`;
  document.querySelector("#fieldAccess").onclick=()=>{S.mode="field";route();};
  document.querySelector("#treatmentAccess").onclick=()=>{S.mode="treatment";route();};
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

  // A browser refresh restores the last organization/event. If permissions
  // changed or that organization no longer exists, gracefully fall back.
  if(S.orgId && !S.orgs.some(o=>o.organization_id===S.orgId)){
    S.orgId=null;
    S.eventId=null;
  }

  if(!S.orgId){
    if(S.orgs.length===1)S.orgId=S.orgs[0].organization_id;
    else{
      saveNavigationState();
      return orgPicker();
    }
  }

  const {data,error}=await supabase.rpc("staff_events_for_org",{p_organization_id:S.orgId});
  if(error){
    console.error("Could not restore event list",error);
    S.eventId=null;
    saveNavigationState();
    return eventPicker();
  }

  S.events=data||[];

  if(S.eventId && !S.events.some(e=>e.id===S.eventId)){
    S.eventId=null;
  }

  saveNavigationState();
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
  document.querySelectorAll("[data-org]").forEach(b=>b.onclick=()=>{S.orgId=b.dataset.org;S.eventId=null;saveNavigationState();staffFlow();});
  document.querySelector("#orgLogout").onclick=async()=>{await supabase.auth.signOut();S.mode=null;reset();clearNavigationState();route();};
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
        <button class="btn" id="newEvent">+ Create Event</button><button class="btn secondary" id="venueLibrary">Venue Library</button><button class="btn secondary" id="orgSettings">Organization Staff</button><button class="btn secondary" id="changeOrg">Organizations</button><button class="btn secondary" id="logout">Sign out</button>
      </div></div>
      ${S.events.map(e=>`<button class="choice" data-event="${e.id}">
        <strong>${esc(e.name)}</strong><br><span class="muted">${esc(e.event_code)} · ${esc(e.staff_role)}</span>
      </button>`).join("")||`<div class="card">No events yet.</div>`}
    </div></div>`;
  document.querySelector("#logout").onclick=async()=>{await supabase.auth.signOut();S.mode=null;reset();clearNavigationState();route();};
  document.querySelector("#changeOrg").onclick=()=>{S.orgId=null;S.eventId=null;saveNavigationState();orgPicker();};
  document.querySelector("#orgSettings").onclick=()=>organizationStaffPage();
  document.querySelector("#venueLibrary").onclick=()=>venueLibraryPage();
  document.querySelector("#newEvent").onclick=()=>newEventForm();
  document.querySelectorAll("[data-event]").forEach(b=>b.onclick=()=>{S.eventId=b.dataset.event;saveNavigationState();dispatchPage();});
}


async function venueLibraryPage(){
  const org=S.orgs.find(o=>o.organization_id===S.orgId);
  try{
    await renderVenueLibrary(app,S.orgId,org?.organizations?.name||"Organization",{
      onBack:()=>eventPicker(),
      onUseVersion:versionId=>newEventForm(versionId)
    });
  }catch(error){
    alert(error.message);
    eventPicker();
  }
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


async function newEventForm(preselectedVersionId=null){
  const org=S.orgs.find(o=>o.organization_id===S.orgId);
  let venues=[];
  try{
    venues=await loadVenueChoices(S.orgId);
  }catch(error){
    console.warn("Venue library could not be loaded",error);
  }

  app.innerHTML=`<div class="shell">${header(`${org?.organizations?.name||""} · Create Event`)}
    <div class="center"><div class="card stack">
      <h2>Create Event</h2>
      <div><label>Event name</label><input id="eventName" placeholder="American Family Field Concert 2027"></div>
      <div><label>Event ID / field code</label><input id="eventCode" placeholder="AFF27"></div>
      <div><label>4-digit field PIN</label><input id="fieldPin" inputmode="numeric" maxlength="4" placeholder="4821"></div>
      <div><label>Incident prefix</label><input id="prefix" placeholder="AFF27"></div>

      <div>
        <label>Venue / Map Setup</label>
        <select id="venueVersion">
          <option value="">Start with a blank event map</option>
          ${venues.map(v=>`<option value="${v.version_id}" ${v.version_id===preselectedVersionId?"selected":""}>${esc(v.venue_name)} · v${v.version_number}${v.address?` · ${esc(v.address)}`:""}</option>`).join("")}
        </select>
        <div class="small muted" style="margin-top:5px">Selecting a venue copies its published map layers, calibration, zones, POIs, aliases, vertical access points and W3W library into this event as a snapshot.</div>
      </div>

      <button class="btn" id="createEvent">Create Event</button>
      <button class="btn secondary" id="cancel">Cancel</button>
      <div id="eventErr" class="small muted"></div>
    </div></div></div>`;

  document.querySelector("#cancel").onclick=()=>eventPicker();

  document.querySelector("#createEvent").onclick=async()=>{
    const status=document.querySelector("#eventErr");
    status.textContent="Creating event…";

    const {data,error}=await supabase.rpc("create_event",{
      p_organization_id:S.orgId,
      p_name:document.querySelector("#eventName").value.trim(),
      p_event_code:document.querySelector("#eventCode").value.trim().toUpperCase(),
      p_pin:document.querySelector("#fieldPin").value.trim(),
      p_incident_prefix:document.querySelector("#prefix").value.trim().toUpperCase()
    });

    if(error){
      status.textContent=error.message;
      return;
    }

    S.eventId=data;
    saveNavigationState();

    const versionId=document.querySelector("#venueVersion").value;
    if(versionId){
      try{
        await applyVenueVersionToEvent({
          eventId:data,
          versionId,
          onProgress:message=>{status.textContent=message;}
        });
      }catch(venueError){
        console.error("Venue snapshot apply failed",venueError);
        status.textContent=`Event was created, but the venue could not be fully applied: ${venueError.message}`;
        alert(status.textContent);
      }
    }

    await eventAdmin();
  };
}

async function loadEventOps(){
  const [
    eventRes,
    depsRes,
    unitsRes,
    incidentsRes,
    poisRes,
    eventMapRes,
    mapLayersRes,
    zonesRes,
    accessPointsRes,
    accessNodesRes
  ] = await Promise.all([
    supabase.from("events").select("*").eq("id",S.eventId).single(),
    supabase.from("event_departments").select("*").eq("event_id",S.eventId).order("sort_order"),
    supabase.from("units").select("*,event_departments(name,short_name)").eq("event_id",S.eventId).eq("active",true).order("name"),
    // Keep the incident query deliberately simple. Related department/unit
    // records are loaded separately below so a relationship/embed error
    // can never make the entire incident list disappear.
    supabase.from("incidents")
      .select("*")
      .eq("event_id",S.eventId)
      .neq("status","CLOSED")
      .order("created_at",{ascending:false}),
    supabase.from("event_pois").select("*,poi_aliases(alias)").eq("event_id",S.eventId).eq("active",true).order("name"),
    supabase.from("event_maps").select("*").eq("event_id",S.eventId).maybeSingle(),
    supabase.from("event_map_layers").select("*").eq("event_id",S.eventId).eq("active",true).order("sort_order"),
    supabase.from("event_zones").select("*").eq("event_id",S.eventId).eq("active",true).order("sort_order"),
    supabase.from("venue_access_points").select("*").eq("event_id",S.eventId).eq("active",true).order("name"),
    supabase.from("venue_access_point_nodes").select("*")
  ]);

  const baseResults = {
    event: eventRes,
    departments: depsRes,
    units: unitsRes,
    incidents: incidentsRes,
    pois: poisRes,
    eventMap: eventMapRes,
    mapLayers: mapLayersRes,
    zones: zonesRes,
    accessPoints: accessPointsRes,
    accessNodes: accessNodesRes
  };

  const failed = Object.entries(baseResults).filter(([,res])=>res.error);
  if(failed.length){
    for(const [name,res] of failed) console.error(`CommCenter Pro load error: ${name}`, res.error);
    throw new Error(
      "CommCenter Pro could not load event data: " +
      failed.map(([name,res])=>`${name}: ${res.error.message}${res.error.hint?` (${res.error.hint})`:""}`).join(" | ")
    );
  }

  let incidents = incidentsRes.data || [];
  const incidentIds = incidents.map(i=>i.id);

  if(incidentIds.length){
    const [deptLinksRes, unitLinksRes] = await Promise.all([
      supabase.from("incident_departments")
        .select("incident_id,department_id,event_departments(name,short_name)")
        .in("incident_id",incidentIds),
      supabase.from("incident_units")
        .select("incident_id,unit_id,cleared_at,units(name)")
        .in("incident_id",incidentIds)
    ]);

    if(deptLinksRes.error){
      console.error("CommCenter Pro incident department load error", deptLinksRes.error);
    }
    if(unitLinksRes.error){
      console.error("CommCenter Pro incident unit load error", unitLinksRes.error);
    }

    const deptLinks = deptLinksRes.data || [];
    const unitLinks = unitLinksRes.data || [];

    incidents = incidents.map(i=>({
      ...i,
      incident_departments: deptLinks.filter(x=>x.incident_id===i.id),
      incident_units: unitLinks.filter(x=>x.incident_id===i.id)
    }));
  }

  S.event=eventRes.data;
  S.departments=depsRes.data||[];
  S.units=unitsRes.data||[];
  S.incidents=incidents;
  S.pois=poisRes.data||[];
  S.eventMap=eventMapRes.data||null;
  S.mapLayers=mapLayersRes.data||[];
  S.zones=zonesRes.data||[];
  S.accessPoints=accessPointsRes.data||[];
  const apIds=new Set(S.accessPoints.map(a=>a.id));
  S.accessNodes=(accessNodesRes.data||[]).filter(n=>apIds.has(n.access_point_id));
  const preferred=S.mapLayers.find(l=>l.id===S.activeMapLayerId);
  const fallback=S.mapLayers.find(l=>l.is_default&&l.status==="published")||S.mapLayers.find(l=>l.status==="published")||S.mapLayers[0]||null;
  S.activeMapLayerId=(preferred||fallback)?.id||null;
}

function activeMapLayer(){return S.mapLayers.find(l=>l.id===S.activeMapLayerId)||null;}
function zoneName(id){return S.zones.find(z=>z.id===id)?.name||"";}
function layerName(id){return S.mapLayers.find(l=>l.id===id)?.name||"";}


function poiSearchText(p){
  return [
    p.name,
    p.category,
    p.w3w,
    layerName(p.map_layer_id),
    zoneName(p.zone_id),
    ...(p.poi_aliases||[]).map(a=>a.alias)
  ].filter(Boolean).join(" ").toLowerCase();
}

function searchPois(query,limit=12){
  const q=String(query||"").trim().toLowerCase();
  const rows=q
    ? S.pois.filter(p=>poiSearchText(p).includes(q))
    : S.pois;
  return rows.slice(0,limit);
}

function poiResultLabel(p){
  const aliases=(p.poi_aliases||[]).map(a=>a.alias).filter(Boolean);
  return `${p.name}${p.category?` · ${p.category}`:""}${layerName(p.map_layer_id)?` · ${layerName(p.map_layer_id)}`:""}${p.zone_id?` / ${zoneName(p.zone_id)}`:""}${aliases.length?` · aka ${aliases.slice(0,2).join(", ")}`:""}`;
}

function poiLocationObject(p){
  return {
    poi_id:p.id,
    map_x:p.map_x,
    map_y:p.map_y,
    latitude:p.latitude,
    longitude:p.longitude,
    w3w:p.w3w,
    landmark:p.name,
    map_layer_id:p.map_layer_id||null,
    zone_id:p.zone_id||null
  };
}

function poiSearchResultsHtml(query){
  const rows=searchPois(query);
  return rows.map(p=>`<button type="button" class="poi-search-result" data-poi-search-result="${p.id}">
    <strong>${esc(p.name)}</strong>
    <span>${esc([p.poi_scope==="venue_snapshot"?"Venue":"Event",p.category,layerName(p.map_layer_id),p.zone_id?zoneName(p.zone_id):""].filter(Boolean).join(" · "))}</span>
    ${(p.poi_aliases||[]).length?`<small>Aliases: ${esc((p.poi_aliases||[]).map(a=>a.alias).join(", "))}</small>`:""}
    ${p.w3w?`<small>///${esc(p.w3w)}</small>`:""}
  </button>`).join("")||`<div class="small muted poi-no-results">No POIs match that search.</div>`;
}

function bindPoiSearch({inputId,resultsId,onSelect}){
  const input=document.querySelector(`#${inputId}`);
  const results=document.querySelector(`#${resultsId}`);
  if(!input||!results)return;

  const render=()=>{
    results.innerHTML=poiSearchResultsHtml(input.value);
    results.querySelectorAll("[data-poi-search-result]").forEach(btn=>{
      btn.onclick=()=>{
        const p=S.pois.find(x=>x.id===btn.dataset.poiSearchResult);
        if(!p)return;
        input.value=p.name;
        results.innerHTML="";
        onSelect(p);
      };
    });
  };

  input.addEventListener("input",render);
  input.addEventListener("focus",render);
  input.addEventListener("keydown",e=>{
    if(e.key==="Escape")results.innerHTML="";
  });
}

async function focusPoiOnMap(p){
  if(!p)return;
  if(p.map_layer_id && p.map_layer_id!==S.activeMapLayerId){
    S.activeMapLayerId=p.map_layer_id;
    saveNavigationState();
    const selector=document.querySelector("#dispatchLayerSelect");
    if(selector)selector.value=p.map_layer_id;
    await setupDispatchMap();
  }
  const layer=activeMapLayer();
  if(S.map&&layer&&p.map_x!=null&&p.map_y!=null){
    const point=pixelToLeaflet(p.map_x,p.map_y,layer.image_height);
    S.map.setView(point,Math.max(S.map.getZoom(),1));
    L.popup().setLatLng(point).setContent(
      `<strong>${esc(p.name)}</strong><br>${esc(layerName(p.map_layer_id)||"")}${p.zone_id?` · ${esc(zoneName(p.zone_id))}`:""}${p.w3w?`<br>///${esc(p.w3w)}`:""}`
    ).openOn(S.map);
  }
}

function showPoiFinder(){
  const detail=document.querySelector("#detail");
  if(!detail)return;
  detail.innerHTML=`<div class="card stack" data-dispatch-editor="poi-search">
    <div class="row"><strong>Find POI</strong><span class="badge">${S.pois.length} locations</span></div>
    <div>
      <label>Search name, alias, category, level, zone or W3W</label>
      <input id="dispatcherPoiSearch" autocomplete="off" placeholder="e.g. Main Medical, Section 312, Gate 4…">
      <div id="dispatcherPoiResults" class="poi-search-results"></div>
    </div>
    <div id="dispatcherPoiSelected" class="small muted">Start typing to search event POIs.</div>
  </div>`;

  bindPoiSearch({
    inputId:"dispatcherPoiSearch",
    resultsId:"dispatcherPoiResults",
    onSelect:async p=>{
      document.querySelector("#dispatcherPoiSelected").innerHTML=`
        <div class="poi-selected-card">
          <strong>${esc(p.name)}</strong><br>
          ${esc([p.category,layerName(p.map_layer_id),p.zone_id?zoneName(p.zone_id):""].filter(Boolean).join(" · "))}
          ${p.w3w?`<br><strong>///${esc(p.w3w)}</strong>`:""}
          ${(p.poi_aliases||[]).length?`<br><span class="muted">Aliases: ${esc((p.poi_aliases||[]).map(a=>a.alias).join(", "))}</span>`:""}
          <div class="grid2" style="margin-top:10px">
            <button class="btn secondary" id="showPoiOnMap">Show on Map</button>
            <button class="btn" id="createAtPoi">Create Incident Here</button>
          </div>
        </div>`;
      document.querySelector("#showPoiOnMap").onclick=()=>focusPoiOnMap(p);
      document.querySelector("#createAtPoi").onclick=()=>{
        focusPoiOnMap(p);
        incidentForm(poiLocationObject(p));
      };
      await focusPoiOnMap(p);
    }
  });
}

async function storageSigned(path,seconds=3600){
  if(!path)return null;
  const {data,error}=await supabase.storage.from("event-assets").createSignedUrl(path,seconds);
  if(error)throw error;
  return data.signedUrl;
}

/* ---------------- DISPATCH ---------------- */

async function dispatchPage(){
  // The dispatcher route is durable across browser refreshes.
  S.mode="staff";
  saveNavigationState();

  // Prevent detached Leaflet maps and duplicate realtime subscriptions from
  // accumulating every time the CAD refreshes.
  cleanupRealtime();

  try{
    await loadEventOps();
  }catch(err){
    console.error("CommCenter Pro dispatch load failed",err);
    app.innerHTML=`<div class="shell">${header("Dispatch Load Error")}
      <div class="wrap"><div class="notice error">
        <strong>CommCenter Pro could not load the incident board.</strong><br>
        ${esc(err.message)}
      </div>
      <button class="btn" id="retryDispatch" style="margin-top:12px">Retry</button>
      </div></div>`;
    document.querySelector("#retryDispatch").onclick=()=>dispatchPage();
    return;
  }

  app.innerHTML=`<div class="shell">${header(`${esc(S.event?.name||"Event")} · Unified Dispatch`)}
    <div class="cad-grid">
      <aside class="panel left">
        <button class="btn block" id="newIncident">+ New Incident</button>
        <div class="section-title">Active incidents</div><div id="incidentList">${incidentList()}</div>
      </aside>
      <div class="map-wrap"><div class="map-level-toolbar"><span class="section-title">Map Layer</span><select id="dispatchLayerSelect">${S.mapLayers.filter(l=>l.status==="published").map(l=>`<option value="${l.id}" ${l.id===S.activeMapLayerId?"selected":""}>${esc(l.name)}${l.level_code?` · ${esc(l.level_code)}`:""}</option>`).join("")}</select></div><div id="map"></div></div>
      <aside class="panel right">
        <div class="row"><div class="section-title">Units</div></div>
        <div id="unitList">${unitList()}</div>
        <div class="section-title">Incident detail</div><div id="detail" class="muted">Select an incident or click the map.</div>
      </aside>
    </div></div>`;
  document.querySelector("#topActions").innerHTML=`
    <button class="btn secondary" id="poiFinderBtn">Find POI</button>
    <button class="btn secondary" id="emsOpsBtn">EMS Ops</button>
    <button class="btn secondary" id="adminBtn">Event Admin</button>
    <button class="btn secondary" id="reportsBtn">Reports</button>
    <button class="btn secondary" id="eventsBtn">Events</button>
    <button class="btn secondary" id="logoutBtn">Sign out</button>`;
  document.querySelector("#poiFinderBtn").onclick=()=>showPoiFinder();
  document.querySelector("#emsOpsBtn").onclick=()=>renderEmsOps(app,{eventId:S.eventId,event:S.event,header,onBack:()=>dispatchPage(),onAdmin:()=>eventAdmin("ems")});
  document.querySelector("#adminBtn").onclick=()=>eventAdmin();
  document.querySelector("#reportsBtn").onclick=()=>reportsPage();
  document.querySelector("#eventsBtn").onclick=()=>{S.eventId=null;staffFlow();};
  document.querySelector("#logoutBtn").onclick=async()=>{await supabase.auth.signOut();S.mode=null;reset();clearNavigationState();route();};
  document.querySelector("#newIncident").onclick=()=>incidentForm(null);
  document.querySelector("#dispatchLayerSelect")?.addEventListener("change",e=>{S.activeMapLayerId=e.target.value;saveNavigationState();setupDispatchMap();});
  bindIncidentClicks();
  ensureCallTimerTicker();
  await setupDispatchMap();
  subscribeDispatch();
}


function activeAssignmentForUnit(unitId){
  for(const incident of S.incidents){
    const link=(incident.incident_units||[]).find(x=>x.unit_id===unitId && !x.cleared_at);
    if(link)return {incident,link};
  }
  return null;
}

function incidentList(){
  return S.incidents.map(i=>{
    const deps=(i.incident_departments||[]).map(d=>d.event_departments?.short_name||d.event_departments?.name).filter(Boolean).join("/");
    const assigned=(i.incident_units||[]).filter(x=>!x.cleared_at).map(x=>x.units?.name).filter(Boolean);
    return `<div class="incident" data-incident="${i.id}">
      <div class="row"><strong>${esc(i.incident_number)}</strong><span class="incident-head-meta"><span class="call-timer" title="Elapsed call time" data-call-start="${esc(i.created_at)}">00:00</span><span class="badge">${esc(i.priority)}</span></span></div>
      <div>${esc(i.call_type)}</div>
      <div class="small muted">${esc(deps)} · ${esc(layerName(i.map_layer_id))}${i.zone_id?` / ${esc(zoneName(i.zone_id))}`:""} · ${esc(i.landmark||i.w3w||"Mapped")}</div>
      ${assigned.length?`<div class="small" style="margin-top:5px"><strong>${esc(assigned.join(", "))}</strong></div>`:""}
    </div>`;
  }).join("")||`<div class="small muted">No active incidents.</div>`;
}

function unitList(){
  const groups={};
  for(const u of S.units){
    const name=u.event_departments?.name||"Other";
    (groups[name]??=[]).push(u);
  }

  return Object.entries(groups).map(([department,units])=>`
    <div class="section-title">${esc(department)}</div>
    ${units.map(u=>{
      const active=activeAssignmentForUnit(u.id);
      return `<button class="unit unit-button" data-unit-detail="${u.id}">
        <div class="row">
          <strong>${esc(u.name)}</strong>
          <span class="badge status-${esc(u.status)}" data-dispatch-unit-status="${u.id}">${esc(u.status.replaceAll("_"," "))}</span>
        </div>
        <div class="small muted">${active?`Assigned: ${esc(active.incident.incident_number)} · ${esc(active.incident.call_type)}`:"Unassigned"}</div>
      </button>`;
    }).join("")}
  `).join("")||`<div class="small muted">No units configured.</div>`;
}

function bindIncidentClicks(){
  document.querySelectorAll("[data-incident]").forEach(b=>b.onclick=()=>selectIncident(b.dataset.incident));
  document.querySelectorAll("[data-unit-detail]").forEach(b=>b.onclick=()=>selectUnit(b.dataset.unitDetail));
}

function unitStatusOptions(unit){
  const dep=S.departments.find(d=>d.id===unit.department_id);
  const raw=Array.isArray(dep?.status_profile)?dep.status_profile:[];
  return [...new Set(["ASSIGNED",...raw])];
}

function updateDispatcherUnitStatusUI(unitId,status){
  const unit=S.units.find(u=>u.id===unitId);
  if(unit)unit.status=status;

  document.querySelectorAll(`[data-dispatch-unit-status="${unitId}"]`).forEach(badge=>{
    [...badge.classList].filter(c=>c.startsWith("status-")).forEach(c=>badge.classList.remove(c));
    badge.classList.add(`status-${status}`);
    badge.textContent=String(status||"").replaceAll("_"," ");
  });

  document.querySelectorAll(`[data-create-unit-status="${unitId}"]`).forEach(el=>{
    const active=activeAssignmentForUnit(unitId);
    el.textContent=`${String(status||"").replaceAll("_"," ")}${active?` · ${active.incident.incident_number}`:""}`;
  });

  document.querySelectorAll(`[data-status-unit="${unitId}"]`).forEach(select=>{
    if([...select.options].some(o=>o.value===status))select.value=status;
  });

  const openUnit=document.querySelector(`[data-unit-detail-id="${unitId}"]`);
  if(openUnit){
    const select=document.querySelector("#unitStatus");
    if(select && [...select.options].some(o=>o.value===status))select.value=status;
  }
}

async function dispatcherSetUnitStatus(unitId,status,incidentId=null){
  const {error}=await supabase.rpc("staff_set_unit_status",{
    p_unit_id:unitId,
    p_status:status,
    p_incident_id:incidentId
  });
  if(error)return alert(error.message);
  updateDispatcherUnitStatusUI(unitId,status);
}

async function dispatcherUnassign(incidentId,unitId){
  if(!confirm("Remove this unit from the incident?"))return;
  const {error}=await supabase.rpc("unassign_unit",{
    p_incident_id:incidentId,
    p_unit_id:unitId,
    p_new_status:"AVAILABLE"
  });
  if(error)return alert(error.message);
  await dispatchPage();
}

async function dispatcherAssign(incidentId,unitId){
  if(!incidentId||!unitId)return;
  const {error}=await supabase.rpc("assign_unit",{
    p_incident_id:incidentId,
    p_unit_id:unitId
  });
  if(error)return alert(error.message);
  await dispatchPage();
}

function selectIncident(id){
  const i=S.incidents.find(x=>x.id===id);if(!i)return;

  const assignedLinks=(i.incident_units||[]).filter(x=>!x.cleared_at);
  const assignedIds=new Set(assignedLinks.map(x=>x.unit_id));

  document.querySelector("#detail").innerHTML=`<div class="card stack">
    <div class="row"><strong>${esc(i.incident_number)}</strong><span class="incident-head-meta"><span class="call-timer" title="Elapsed call time" data-call-start="${esc(i.created_at)}">00:00</span><span class="badge">${esc(i.priority)}</span></span></div>
    <strong>${esc(i.call_type)}</strong>
    <div class="venue-location-line">${i.map_layer_id?`<span class="badge layer-badge">${esc(layerName(i.map_layer_id))}</span> `:""}${i.zone_id?`<span class="badge">${esc(zoneName(i.zone_id))}</span>`:""}</div>
    <div>${i.w3w?`<strong>///${esc(i.w3w)}</strong><br>`:""}${esc(i.landmark||"")}<br>
    <span class="small mono">${Number(i.latitude).toFixed(6)}, ${Number(i.longitude).toFixed(6)}</span></div>
    <div>${esc(i.notes||"")}</div>

    <div>
      <div class="section-title">Assigned units</div>
      ${assignedLinks.map(link=>{
        const u=S.units.find(x=>x.id===link.unit_id);
        if(!u)return "";
        return `<div class="assignment-unit-row">
          <div>
            <strong>${esc(u.event_departments?.short_name||"")} · ${esc(u.name)}</strong><br>
            <span class="badge status-${esc(u.status)}" data-dispatch-unit-status="${u.id}">${esc(u.status.replaceAll("_"," "))}</span>
          </div>
          <div class="assignment-unit-actions">
            <select data-status-unit="${u.id}">
              ${unitStatusOptions(u).map(st=>`<option value="${esc(st)}" ${st===u.status?"selected":""}>${esc(st.replaceAll("_"," "))}</option>`).join("")}
            </select>
            <button class="btn secondary" data-apply-status="${u.id}">Set Status</button>
            <button class="btn danger" data-unassign-unit="${u.id}">Unassign</button>
          </div>
        </div>`;
      }).join("")||`<div class="small muted">No units assigned.</div>`}
    </div>

    <div>
      <label>Assign another unit</label>
      <select id="assignUnit">
        <option value="">Choose unit</option>
        ${S.units.filter(u=>!assignedIds.has(u.id)).map(u=>{
          const active=activeAssignmentForUnit(u.id);
          return `<option value="${u.id}" ${active?"disabled":""}>${esc(u.event_departments?.short_name||"")} · ${esc(u.name)} · ${esc(u.status)}${active?` · ${esc(active.incident.incident_number)}`:""}</option>`;
        }).join("")}
      </select>
    </div>
    <button class="btn" id="dispatchUnit">Assign Unit</button>
    <button class="btn secondary" id="editIncident">Edit Call Details</button>
    <button class="btn secondary" id="closeIncident">Close Incident</button>
  </div>`;

  document.querySelector("#dispatchUnit").onclick=()=>dispatcherAssign(i.id,document.querySelector("#assignUnit").value);
  document.querySelector("#editIncident").onclick=()=>editIncidentForm(i.id);

  document.querySelectorAll("[data-apply-status]").forEach(b=>b.onclick=()=>{
    const unitId=b.dataset.applyStatus;
    const status=document.querySelector(`[data-status-unit="${unitId}"]`).value;
    dispatcherSetUnitStatus(unitId,status,i.id);
  });

  document.querySelectorAll("[data-unassign-unit]").forEach(b=>b.onclick=()=>dispatcherUnassign(i.id,b.dataset.unassignUnit));

  document.querySelector("#closeIncident").onclick=async()=>{
    const disposition=prompt("Disposition:","Complete");
    const {error}=await supabase.rpc("close_incident",{p_incident_id:i.id,p_disposition:disposition});
    if(error)alert(error.message);else dispatchPage();
  };

  if(i.map_layer_id && i.map_layer_id!==S.activeMapLayerId){
    S.activeMapLayerId=i.map_layer_id;
    saveNavigationState();
    setupDispatchMap().then(()=>{
      const l=activeMapLayer();if(S.map&&l&&i.map_x!=null&&i.map_y!=null)S.map.setView(pixelToLeaflet(i.map_x,i.map_y,l.image_height),Math.max(S.map.getZoom(),0));
    });
  }else{const l=activeMapLayer();if(S.map&&l&&i.map_x!=null&&i.map_y!=null)S.map.setView(pixelToLeaflet(i.map_x,i.map_y,l.image_height),Math.max(S.map.getZoom(),0));}

}

function selectUnit(unitId){
  const u=S.units.find(x=>x.id===unitId);if(!u)return;
  const active=activeAssignmentForUnit(unitId);

  document.querySelector("#detail").innerHTML=`<div class="card stack" data-unit-detail-id="${u.id}">
    <div class="row">
      <div><div class="section-title">${esc(u.event_departments?.name||"Unit")}</div><div class="big" style="font-size:20px">${esc(u.name)}</div></div>
      <span class="badge status-${esc(u.status)}" data-dispatch-unit-status="${u.id}">${esc(u.status.replaceAll("_"," "))}</span>
    </div>

    ${active?`<div class="notice">
      <strong>Current assignment</strong><br>
      ${esc(active.incident.incident_number)} · ${esc(active.incident.call_type)}<br>
      ${esc(active.incident.landmark||active.incident.w3w||"")}
    </div>`:`<div class="notice ok"><strong>Unassigned</strong></div>`}

    <div>
      <label>Dispatcher status</label>
      <select id="unitStatus">
        ${unitStatusOptions(u).map(st=>`<option value="${esc(st)}" ${st===u.status?"selected":""}>${esc(st.replaceAll("_"," "))}</option>`).join("")}
      </select>
    </div>
    <button class="btn secondary" id="setUnitStatus">Set Status</button>

    <div class="venue-unit-location"><div class="section-title">Current Venue Location</div><select id="unitLayer"><option value="">No level/post</option>${S.mapLayers.filter(l=>l.status==="published").map(l=>`<option value="${l.id}" ${u.current_map_layer_id===l.id?"selected":""}>${esc(l.name)}</option>`).join("")}</select><select id="unitZone"><option value="">No zone</option>${S.zones.filter(z=>!u.current_map_layer_id||z.map_layer_id===u.current_map_layer_id).map(z=>`<option value="${z.id}" ${u.current_zone_id===z.id?"selected":""}>${esc(z.name)}</option>`).join("")}</select><button class="btn secondary" id="saveUnitLocation">Update Post</button></div>

    ${active?`
      <button class="btn" id="openAssignedIncident">Open ${esc(active.incident.incident_number)}</button>
      <button class="btn danger" id="removeAssignment">Unassign from ${esc(active.incident.incident_number)}</button>
    `:`
      <div>
        <label>Assign to incident</label>
        <select id="unitIncident">
          <option value="">Choose active incident</option>
          ${S.incidents.map(i=>`<option value="${i.id}">${esc(i.incident_number)} · ${esc(i.call_type)} · ${esc(i.landmark||"")}</option>`).join("")}
        </select>
      </div>
      <button class="btn" id="assignFromUnit">Assign to Incident</button>
    `}
  </div>`;

  document.querySelector("#setUnitStatus").onclick=()=>dispatcherSetUnitStatus(unitId,document.querySelector("#unitStatus").value,active?.incident.id||null);
  document.querySelector("#unitLayer").onchange=e=>{const layer=e.target.value;document.querySelector("#unitZone").innerHTML=`<option value="">No zone</option>${S.zones.filter(z=>z.map_layer_id===layer).map(z=>`<option value="${z.id}">${esc(z.name)}</option>`).join("")}`;};
  document.querySelector("#saveUnitLocation").onclick=async()=>{const {error}=await supabase.rpc("staff_set_unit_location",{p_unit_id:unitId,p_map_layer_id:document.querySelector("#unitLayer").value||null,p_zone_id:document.querySelector("#unitZone").value||null,p_poi_id:null});if(error)alert(error.message);else dispatchPage();};

  if(active){
    document.querySelector("#openAssignedIncident").onclick=()=>selectIncident(active.incident.id);
    document.querySelector("#removeAssignment").onclick=()=>dispatcherUnassign(active.incident.id,unitId);
  }else{
    document.querySelector("#assignFromUnit").onclick=()=>dispatcherAssign(document.querySelector("#unitIncident").value,unitId);
  }
}
async function setupDispatchMap(){
  if(S.map){try{S.map.remove()}catch{}S.map=null;}
  const layer=activeMapLayer();
  if(!layer?.rendered_image_path || layer.status!=="published"){
    S.map=L.map("map",{crs:L.CRS.Simple,attributionControl:false}).setView([0,0],0);
    L.popup().setLatLng([0,0]).setContent("No published map layer selected. Open Event Admin → Map Builder.").openOn(S.map);
    return;
  }
  const url=await storageSigned(layer.rendered_image_path);
  S.map=L.map("map",{crs:L.CRS.Simple,minZoom:-4,maxZoom:5,zoomSnap:.25,attributionControl:false});
  const bounds=[[0,0],[layer.image_height,layer.image_width]];
  L.imageOverlay(url,bounds).addTo(S.map);S.map.fitBounds(bounds);

  for(const p of S.pois.filter(p=>p.map_layer_id===layer.id)){
    L.marker(pixelToLeaflet(p.map_x,p.map_y,layer.image_height)).addTo(S.map).bindTooltip(`${p.name}${p.w3w?` · ///${p.w3w}`:""}`);
  }
  for(const n of S.accessNodes.filter(n=>n.map_layer_id===layer.id)){
    const ap=S.accessPoints.find(a=>a.id===n.access_point_id);
    L.circleMarker(pixelToLeaflet(n.map_x,n.map_y,layer.image_height),{radius:6,className:"access-marker"}).addTo(S.map).bindTooltip(`${ap?.name||"Access"} · ${ap?.access_type||""}`);
  }
  for(const i of S.incidents.filter(i=>!i.map_layer_id||i.map_layer_id===layer.id)){
    if(i.map_x!=null&&i.map_y!=null)L.circleMarker(pixelToLeaflet(i.map_x,i.map_y,layer.image_height),{radius:8,className:"incident-marker"}).addTo(S.map).bindTooltip(i.incident_number);
  }
  if(layer.georef_coefficients){
    S.map.on("click",async e=>{
      const px=leafletToPixel(e.latlng,layer.image_height);
      const geo=pixelToGeo(px.x,px.y,layer.georef_coefficients);
      const {data:words}=await supabase.rpc("w3w_for_coordinate",{p_event_id:S.eventId,p_lat:geo.lat,p_lon:geo.lon});
      S.currentLocation={map_x:px.x,map_y:px.y,latitude:geo.lat,longitude:geo.lon,w3w:words||null,poi_id:null,landmark:"",map_layer_id:layer.id,zone_id:null};
      L.popup().setLatLng(e.latlng).setContent(`<strong>${esc(layer.name)}</strong><br>${words?`///${esc(words)}<br>`:""}${geo.lat.toFixed(6)}, ${geo.lon.toFixed(6)}<br><br><button id="createAtPoint">Create incident here</button>`).openOn(S.map);
      setTimeout(()=>document.querySelector("#createAtPoint")?.addEventListener("click",()=>incidentForm(S.currentLocation)),0);
    });
  }
}


function incidentForm(loc){
  const detail=document.querySelector("#detail");

  detail.innerHTML=`<div class="card stack" data-dispatch-editor="new"><strong>New Incident</strong>
    <div>
      <label>Search POI / Common Name</label>
      <input id="poiSearchNew" autocomplete="off" placeholder="Search name, alias, section, gate, category…">
      <div id="poiSearchNewResults" class="poi-search-results"></div>
    </div>

    <div><label>Departments</label>${S.departments.map(d=>`<label style="font-weight:500"><input type="checkbox" name="dept" value="${d.id}"> ${esc(d.name)}</label>`).join("")}</div>
    <div><label>Call type</label><input id="callType" placeholder="Medical, disturbance, power issue…"></div>
    <div><label>Priority</label><select id="priority"><option>Standard</option><option>Urgent</option><option>Critical</option></select></div>
    <div><label>Location description</label><input id="landmark" value="${esc(loc?.landmark||"")}"></div>
    <div><label>Dispatch notes</label><textarea id="notes" rows="4"></textarea></div>
    <div id="locSummary" class="small muted">${loc?`${loc.map_layer_id?`${esc(layerName(loc.map_layer_id))} · `:""}${loc.w3w?`///${esc(loc.w3w)} · `:""}${Number(loc.latitude).toFixed(6)}, ${Number(loc.longitude).toFixed(6)}`:"Choose a POI or click the map first."}</div>

    <div>
      <div class="section-title">Initial unit assignment</div>
      <div class="small muted" style="margin-bottom:7px">Optional. Select one or more unassigned units.</div>
      <div class="create-unit-grid">
        ${S.units.map(u=>{
          const active=activeAssignmentForUnit(u.id);
          return `<label class="create-unit-option ${active?"disabled":""}">
            <input type="checkbox" name="initialUnit" value="${u.id}" ${active?"disabled":""}>
            <span><strong>${esc(u.event_departments?.short_name||"")} · ${esc(u.name)}</strong><br>
            <span class="small muted" data-create-unit-status="${u.id}">${esc(u.status.replaceAll("_"," "))}${active?` · ${esc(active.incident.incident_number)}`:""}</span></span>
          </label>`;
        }).join("")||`<div class="small muted">No units configured.</div>`}
      </div>
    </div>

    <div class="grid2">
      <button class="btn secondary" id="saveIncidentOnly">Create Without Assignment</button>
      <button class="btn" id="saveAndDispatch">Create & Dispatch Selected</button>
    </div>
  </div>`;

  let chosen=loc?{...loc}:null;

  bindPoiSearch({
    inputId:"poiSearchNew",
    resultsId:"poiSearchNewResults",
    onSelect:p=>{
      chosen=poiLocationObject(p);
      document.querySelector("#landmark").value=p.name;
      document.querySelector("#locSummary").textContent=`${layerName(p.map_layer_id)||"Unlayered"}${p.zone_id?` / ${zoneName(p.zone_id)}`:""} · ${p.w3w?`///${p.w3w} · `:""}${Number(p.latitude).toFixed(6)}, ${Number(p.longitude).toFixed(6)}`;
      focusPoiOnMap(p);
    }
  });

  const create=async(assignSelected)=>{
    if(!chosen)return alert("Choose a POI or click the map to set the incident location.");
    const deps=[...document.querySelectorAll('input[name="dept"]:checked')].map(x=>x.value);
    if(!deps.length)return alert("Choose at least one department.");

    const selectedUnits=assignSelected
      ? [...document.querySelectorAll('input[name="initialUnit"]:checked')].map(x=>x.value)
      : [];

    const {data,error}=await supabase.rpc("create_incident_v2",{
      p_event_id:S.eventId,
      p_department_ids:deps,
      p_call_type:document.querySelector("#callType").value.trim()||"Other",
      p_priority:document.querySelector("#priority").value,
      p_latitude:chosen.latitude,
      p_longitude:chosen.longitude,
      p_map_x:chosen.map_x,
      p_map_y:chosen.map_y,
      p_w3w:chosen.w3w,
      p_landmark:document.querySelector("#landmark").value.trim(),
      p_notes:document.querySelector("#notes").value.trim(),
      p_poi_id:chosen.poi_id||null,
      p_map_layer_id:chosen.map_layer_id||S.activeMapLayerId||null,
      p_zone_id:chosen.zone_id||null
    });

    if(error){
      console.error("CommCenter Pro create incident error",error);
      return alert(`Incident was NOT created.\n\n${error.message}${error.hint?`\n\nHint: ${error.hint}`:""}`);
    }

    const createdId=data;
    const failures=[];

    for(const unitId of selectedUnits){
      const result=await supabase.rpc("assign_unit",{p_incident_id:createdId,p_unit_id:unitId});
      if(result.error)failures.push(result.error.message);
    }

    await dispatchPage();
    if(createdId)setTimeout(()=>selectIncident(createdId),50);

    if(failures.length){
      alert(`Incident created, but one or more units could not be assigned:\n\n${failures.join("\n")}`);
    }
  };

  document.querySelector("#saveIncidentOnly").onclick=()=>create(false);
  document.querySelector("#saveAndDispatch").onclick=()=>create(true);
}


function editIncidentForm(incidentId){
  const i=S.incidents.find(x=>x.id===incidentId);
  if(!i)return;

  let chosen={
    poi_id:i.poi_id||null,
    map_x:i.map_x,
    map_y:i.map_y,
    latitude:i.latitude,
    longitude:i.longitude,
    w3w:i.w3w,
    landmark:i.landmark,
    map_layer_id:i.map_layer_id||null,
    zone_id:i.zone_id||null
  };

  const selectedDepartments=new Set((i.incident_departments||[]).map(d=>d.department_id));
  const detail=document.querySelector("#detail");

  detail.innerHTML=`<div class="card stack" data-dispatch-editor="edit">
    <div class="row">
      <div><div class="section-title">Edit Incident</div><strong>${esc(i.incident_number)}</strong></div>
      <span class="call-timer" data-call-start="${esc(i.created_at)}">00:00</span>
    </div>

    <div>
      <label>Departments</label>
      <div class="incident-department-picker">
        ${S.departments.map(d=>`<label class="status-select-option">
          <input type="checkbox" name="editDept" value="${d.id}" ${selectedDepartments.has(d.id)?"checked":""}>
          <span>${esc(d.name)}</span>
        </label>`).join("")}
      </div>
    </div>

    <div><label>Call Type / Nature</label><input id="editCallType" value="${esc(i.call_type)}"></div>

    <div><label>Priority</label><select id="editPriority">
      ${["Standard","Urgent","Critical"].map(p=>`<option ${i.priority===p?"selected":""}>${p}</option>`).join("")}
    </select></div>

    <div>
      <label>Change Location Using POI</label>
      <input id="poiSearchEdit" autocomplete="off" placeholder="Search POIs; leave unchanged to keep current location">
      <div id="poiSearchEditResults" class="poi-search-results"></div>
    </div>

    <div class="notice">
      <strong>Current selected location</strong><br>
      <span id="editLocationSummary">${esc(layerName(i.map_layer_id)||"Unlayered")}${i.zone_id?` / ${esc(zoneName(i.zone_id))}`:""} · ${esc(i.landmark||"")}${i.w3w?` · ///${esc(i.w3w)}`:""}</span>
    </div>

    <div><label>Location Description</label><input id="editLandmark" value="${esc(i.landmark||"")}"></div>
    <div><label>Dispatch Notes</label><textarea id="editNotes" rows="5">${esc(i.notes||"")}</textarea></div>

    <div class="grid2">
      <button class="btn secondary" id="cancelIncidentEdit">Cancel</button>
      <button class="btn" id="saveIncidentEdit">Save Changes</button>
    </div>
  </div>`;

  ensureCallTimerTicker();

  bindPoiSearch({
    inputId:"poiSearchEdit",
    resultsId:"poiSearchEditResults",
    onSelect:p=>{
      chosen=poiLocationObject(p);
      document.querySelector("#editLandmark").value=p.name;
      document.querySelector("#editLocationSummary").textContent=`${layerName(p.map_layer_id)||"Unlayered"}${p.zone_id?` / ${zoneName(p.zone_id)}`:""} · ${p.name}${p.w3w?` · ///${p.w3w}`:""}`;
      focusPoiOnMap(p);
    }
  });

  document.querySelector("#cancelIncidentEdit").onclick=()=>selectIncident(incidentId);

  document.querySelector("#saveIncidentEdit").onclick=async()=>{
    const departments=[...document.querySelectorAll('input[name="editDept"]:checked')].map(x=>x.value);
    if(!departments.length)return alert("Choose at least one department.");

    const callType=document.querySelector("#editCallType").value.trim();
    if(!callType)return alert("Enter a call type / nature.");

    const {error}=await supabase.rpc("update_incident_v2",{
      p_incident_id:incidentId,
      p_department_ids:departments,
      p_call_type:callType,
      p_priority:document.querySelector("#editPriority").value,
      p_latitude:chosen.latitude,
      p_longitude:chosen.longitude,
      p_map_x:chosen.map_x,
      p_map_y:chosen.map_y,
      p_w3w:chosen.w3w,
      p_landmark:document.querySelector("#editLandmark").value.trim(),
      p_notes:document.querySelector("#editNotes").value.trim(),
      p_poi_id:chosen.poi_id||null,
      p_map_layer_id:chosen.map_layer_id||null,
      p_zone_id:chosen.zone_id||null
    });

    if(error)return alert(`Call was not updated.\n\n${error.message}`);

    // Reload data without rebuilding the entire application shell.
    await loadEventOps();
    document.querySelector("#incidentList").innerHTML=incidentList();
    document.querySelector("#unitList").innerHTML=unitList();
    bindIncidentClicks();
    selectIncident(incidentId);
  };
}

/* ---------------- EVENT ADMIN ---------------- */

async function eventAdmin(initialTab="setup"){
  await loadEventOps();
  app.innerHTML=`<div class="shell">${header(`${esc(S.event?.name||"Event")} · Event Admin`)}
    <div class="admin-layout">
      <aside class="admin-menu">
        <button class="${initialTab==="setup"?"active":""}" id="setupTab">Setup</button>
        <button class="${initialTab==="ems"?"active":""}" id="emsTab">EMS Setup</button>
        <button id="mapTab">Map Builder</button>
        <button id="backDispatch">Back to CAD</button>
      </aside>
      <main class="admin-content"><div id="adminContent"></div></main>
    </div></div>`;
  document.querySelector("#backDispatch").onclick=()=>dispatchPage();
  const markAdminTab=(activeId)=>{
    document.querySelectorAll(".admin-menu button").forEach(b=>b.classList.remove("active"));
    document.querySelector(`#${activeId}`)?.classList.add("active");
  };
  const showEmsAdmin=async()=>{
    markAdminTab("emsTab");
    await loadEventOps();
    await renderEmsAdmin(
      document.querySelector("#adminContent"),
      {eventId:S.eventId,event:S.event,units:S.units,pois:S.pois,departments:S.departments},
      showEmsAdmin
    );
  };
  document.querySelector("#mapTab").onclick=()=>renderMapBuilder(app,S.eventId,()=>eventAdmin());
  document.querySelector("#setupTab").onclick=()=>{markAdminTab("setupTab");renderEventSetup();};
  document.querySelector("#emsTab").onclick=showEmsAdmin;
  if(initialTab==="ems")showEmsAdmin();else renderEventSetup();
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
      <div id="deptList">${S.departments.map(d=>`<div class="poi-row department-row">
        <div class="row">
          <div><strong>${esc(d.name)}</strong> <span class="muted">${esc(d.short_name||"")}</span></div>
          <button class="btn secondary" data-edit-dept-statuses="${d.id}">Edit Statuses</button>
        </div>
        <div class="department-status-badges">
          ${(Array.isArray(d.status_profile)?d.status_profile:[]).map(st=>`<span class="badge status-choice-badge">${esc(statusLabel(st))}</span>`).join("")||`<span class="small muted">No field statuses configured</span>`}
        </div>
      </div>`).join("")||`<div class="small muted">No departments configured yet.</div>`}</div>

      <div id="deptStatusEditor"></div>

      <div class="section-title">Add Department</div>
      <div class="grid2">
        <div><label>Department Name</label><input id="deptName" placeholder="Police"></div>
        <div><label>Short Name</label><input id="deptShort" placeholder="PD"></div>
      </div>

      <div style="margin-top:12px">
        <label>Field Unit Status Options</label>
        <div class="small muted" style="margin-bottom:8px">Select the buttons field units in this department should have available. ASSIGNED is handled automatically by Dispatch.</div>
        ${departmentStatusPicker("newDeptStatuses")}
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
      <div class="row">
        <div><h2>Venue Maps</h2><p><strong>${S.mapLayers.length}</strong> map layer${S.mapLayers.length===1?"":"s"} configured · Venue type: <strong>${esc(S.event.venue_type||"outdoor")}</strong></p></div>
        ${S.event.venue_version_id?`<span class="badge">Venue Snapshot</span>`:`<span class="badge">Event Only</span>`}
      </div>
      <div class="grid2">
        <button class="btn" id="openMapBuilder">Open Map Builder</button>
        <button class="btn secondary" id="saveVenueLibrary">Save / Update Venue Library</button>
      </div>
      <div id="venueSavePanel"></div>
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
  document.querySelectorAll("[data-edit-dept-statuses]").forEach(btn=>{
    btn.onclick=()=>renderDepartmentStatusEditor(btn.dataset.editDeptStatuses);
  });

  document.querySelector("#addDept").onclick=async()=>{
    const name=document.querySelector("#deptName").value.trim();
    const shortName=document.querySelector("#deptShort").value.trim().toUpperCase();
    const statuses=selectedDepartmentStatuses("newDeptStatuses");

    if(!name)return alert("Enter a department name.");
    if(!statuses.length)return alert("Select at least one field unit status.");

    const {error}=await supabase.from("event_departments").insert({
      event_id:S.eventId,
      name,
      short_name:shortName,
      status_profile:statuses
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
  document.querySelector("#saveVenueLibrary").onclick=()=>renderVenueSavePanel();
}



async function renderVenueSavePanel(){
  const host=document.querySelector("#venueSavePanel");
  if(!host)return;

  let venues=[];
  try{
    venues=await loadVenueChoices(S.orgId);
  }catch(error){
    return alert(error.message);
  }

  const linkedVenue=venues.find(v=>v.venue_id===S.event.venue_id);

  host.innerHTML=`<div class="venue-save-panel">
    <div class="row">
      <div>
        <div class="section-title">Reusable Venue Template</div>
        <strong>${linkedVenue?`Create a new version of ${esc(linkedVenue.venue_name)}`:"Save this event map as a reusable venue"}</strong>
      </div>
      <button class="btn secondary" id="cancelVenueSave">Cancel</button>
    </div>

    ${linkedVenue?`
      <input type="hidden" id="venueExistingId" value="${linkedVenue.venue_id}">
      <div class="notice">This event is based on <strong>${esc(linkedVenue.venue_name)}</strong>. Saving creates a new immutable venue version; older events stay on their existing snapshots.</div>
    `:`
      <div><label>Venue Name</label><input id="venueName" placeholder="American Family Field"></div>
      <div><label>Venue Address</label><input id="venueAddress" placeholder="1 Brewers Way, Milwaukee, WI"></div>
    `}

    <div><label>Version Notes</label><input id="venueNotes" placeholder="Updated 300-level map and medical POIs"></div>

    ${S.event.venue_id?`
      <label class="venue-promote-check"><input type="checkbox" id="includeEventPois"> Include event-only POIs in this new venue version</label>
      <div class="small muted">Leave this off for temporary locations such as event-specific EMS staging, tour compounds or credentialing. Turn it on when those event POIs should become permanent venue POIs.</div>
    `:""}

    <button class="btn" id="confirmVenueSave">${linkedVenue?"Create New Venue Version":"Save Venue to Organization"}</button>
    <div id="venueSaveStatus" class="small muted"></div>
  </div>`;

  document.querySelector("#cancelVenueSave").onclick=()=>{host.innerHTML="";};

  document.querySelector("#confirmVenueSave").onclick=async()=>{
    const status=document.querySelector("#venueSaveStatus");
    const venueId=document.querySelector("#venueExistingId")?.value||null;
    const venueName=document.querySelector("#venueName")?.value.trim()||null;
    const address=document.querySelector("#venueAddress")?.value.trim()||null;

    if(!venueId&&!venueName)return alert("Enter a venue name.");

    try{
      const result=await saveEventToVenueLibrary({
        eventId:S.eventId,
        organizationId:S.orgId,
        venueId,
        venueName,
        address,
        notes:document.querySelector("#venueNotes").value.trim(),
        includeEventPois:document.querySelector("#includeEventPois")?.checked||false,
        onProgress:message=>{status.textContent=message;}
      });
      await loadEventOps();
      status.textContent=`Saved ${result.venue_name} v${result.version_number}. Future events can now start from this venue.`;
    }catch(error){
      console.error("Venue save failed",error);
      status.textContent=error.message;
    }
  };
}

function renderDepartmentStatusEditor(departmentId){
  const dep=S.departments.find(d=>d.id===departmentId);
  if(!dep)return;

  const host=document.querySelector("#deptStatusEditor");
  host.innerHTML=`<div class="department-status-editor">
    <div class="row">
      <div>
        <div class="section-title">Edit Field Statuses</div>
        <strong>${esc(dep.name)}</strong>
      </div>
      <button class="btn secondary" id="cancelDeptStatusEdit">Cancel</button>
    </div>
    <p class="small muted">These become the selectable status buttons on field devices assigned to ${esc(dep.name)}.</p>
    ${departmentStatusPicker("editDeptStatuses",dep.status_profile)}
    <button class="btn" id="saveDeptStatuses">Save Status Options</button>
  </div>`;

  document.querySelector("#cancelDeptStatusEdit").onclick=()=>{host.innerHTML="";};
  document.querySelector("#saveDeptStatuses").onclick=async()=>{
    const statuses=selectedDepartmentStatuses("editDeptStatuses");
    if(!statuses.length)return alert("Select at least one field unit status.");

    const {error}=await supabase.from("event_departments")
      .update({status_profile:statuses})
      .eq("id",departmentId)
      .eq("event_id",S.eventId);

    if(error)return alert(error.message);

    await loadEventOps();
    renderEventSetup();
  };

  host.scrollIntoView({behavior:"smooth",block:"nearest"});
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
      ${(units||[]).filter(u=>u.department_id===d.id).map(u=>`<button class="choice" data-unit="${u.id}"><strong>${esc(u.name)}</strong><br><span class="badge status-${esc(u.status)}" data-dispatch-unit-status="${u.id}">${esc(u.status.replaceAll("_"," "))}</span></button>`).join("")}
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
  let fieldLayer=null,fieldZone=null;
  if(incident?.map_layer_id){fieldLayer=(await supabase.from("event_map_layers").select("id,name,level_code").eq("id",incident.map_layer_id).maybeSingle()).data||null;}
  if(incident?.zone_id){fieldZone=(await supabase.from("event_zones").select("id,name").eq("id",incident.zone_id).maybeSingle()).data||null;}
  const statuses=fs.units?.event_departments?.status_profile||["AVAILABLE","RESPONDING","ON_SCENE","CLEAR"];
  let emsState=null;
  try{emsState=await loadFieldEmsState(S.eventId,fs.unit_id,incident?.id||null);}catch(err){console.error("Field EMS panel failed to load",err);}

  app.innerHTML=`<div class="shell">${header(`${esc(fs.events?.name||"")} · ${esc(fs.units?.event_departments?.name||"")}`)}
    <div class="field-shell stack">
      <div class="card"><div class="small muted">Your unit</div><div class="big">${esc(fs.units?.name)}</div><span class="badge status-${esc(fs.units?.status)}" data-field-unit-status>${esc(fs.units?.status?.replaceAll("_"," "))}</span></div>
      ${incident?`<div class="card assignment"><div class="row"><strong>${esc(incident.incident_number)}</strong><span class="incident-head-meta"><span class="call-timer field-call-timer" title="Elapsed call time" data-call-start="${esc(incident.created_at)}">00:00</span><span class="badge">${esc(incident.priority)}</span></span></div>
        <h2>${esc(incident.call_type)}</h2>${fieldLayer?`<div class="venue-location-line"><span class="badge layer-badge">${esc(fieldLayer.name)}</span>${fieldZone?` <span class="badge">${esc(fieldZone.name)}</span>`:""}</div>`:""}<p>${incident.w3w?`<strong>///${esc(incident.w3w)}</strong><br>`:""}${esc(incident.landmark||"")}<br>
        <span class="small mono">${Number(incident.latitude).toFixed(6)}, ${Number(incident.longitude).toFixed(6)}</span></p><p>${esc(incident.notes||"")}</p>
        <button class="btn secondary block" id="viewFieldMap">View on Event Map</button>
        <div id="fieldMapHolder"></div>
      </div>`:`<div class="card"><strong>No current assignment</strong><p class="muted">Remain available for dispatch.</p></div>`}
      ${fieldEmsPanelHtml(emsState,incident)}
      <div class="status-buttons">${statuses.map(s=>`<button class="btn ${["AVAILABLE","CLEAR","COMPLETE"].includes(s)?"good":""} ${s===fs.units?.status?"field-status-active":""}" data-status="${esc(s)}">${esc(s.replaceAll("_"," "))}</button>`).join("")}</div>
      <div class="notice ${navigator.onLine?"ok":""}">${navigator.onLine?"Connected":"Offline — CAD changes cannot reach dispatch until connectivity returns."}</div>
      <button class="btn secondary" id="downloadOffline">Download Event Map + W3W for Offline Use</button>
      <div id="offlineStatus" class="small muted"></div>
      <button class="btn secondary" id="changeUnit">Change Unit</button><button class="btn secondary" id="leaveEvent">Leave Event</button>
    </div></div>`;
  ensureCallTimerTicker();
  document.querySelectorAll("[data-status]").forEach(b=>b.onclick=async()=>{
    const requested=b.dataset.status;
    b.disabled=true;
    const {error}=await supabase.rpc("field_set_unit_status",{p_unit_id:fs.unit_id,p_status:requested,p_incident_id:incident?.id||null,p_client_time:new Date().toISOString()});
    b.disabled=false;
    if(error)return alert(error.message);
    fs.units.status=requested;
    updateFieldUnitStatusUI(requested);
  });
  bindFieldEmsPanel(emsState,{eventId:S.eventId,unitId:fs.unit_id,incident,refresh:()=>fieldUnitCad()});
  document.querySelector("#downloadOffline").onclick=()=>downloadOfflineEventData();
  getOfflineEvent(S.eventId).then(x=>{if(x)document.querySelector("#offlineStatus").textContent=`Offline package saved ${new Date(x.savedAt).toLocaleString()}`;}).catch(()=>{});
  document.querySelector("#changeUnit").onclick=async()=>{await supabase.rpc("field_release_unit",{p_field_session_id:fs.id});fieldUnitPicker();};
  document.querySelector("#leaveEvent").onclick=leaveField;
  if(incident)document.querySelector("#viewFieldMap").onclick=()=>showFieldMap(incident);
  subscribeField(fs.unit_id);
}
function updateFieldUnitStatusUI(status){
  const badge=document.querySelector("[data-field-unit-status]");
  if(badge){
    [...badge.classList].filter(c=>c.startsWith("status-")).forEach(c=>badge.classList.remove(c));
    badge.classList.add(`status-${status}`);
    badge.textContent=String(status||"").replaceAll("_"," ");
  }

  document.querySelectorAll("[data-status]").forEach(btn=>{
    btn.classList.toggle("field-status-active",btn.dataset.status===status);
    btn.setAttribute("aria-pressed",btn.dataset.status===status?"true":"false");
  });
}

async function downloadOfflineEventData(){
  const status=document.querySelector("#offlineStatus");
  try{
    status.textContent="Downloading venue map package…";
    const [{data:layers,error:layersErr},{data:pois,error:poisErr},{data:event,error:eventErr}]=await Promise.all([
      supabase.from("event_map_layers").select("*").eq("event_id",S.eventId).eq("active",true).eq("status","published").order("sort_order"),
      supabase.from("event_pois").select("id,name,category,w3w,latitude,longitude,map_x,map_y,map_layer_id,zone_id,notes").eq("event_id",S.eventId).eq("active",true),
      supabase.from("events").select("offline_w3w_path").eq("id",S.eventId).single()
    ]);
    if(layersErr)throw layersErr;if(poisErr)throw poisErr;if(eventErr)throw eventErr;
    if(!(layers||[]).length)throw new Error("No published map layers.");

    const offlineLayers=[];
    for(const layer of layers){
      status.textContent=`Downloading ${layer.name}…`;
      const {data:mapBlob,error}=await supabase.storage.from("event-assets").download(layer.rendered_image_path);
      if(error)throw error;
      offlineLayers.push({meta:layer,mapBlob});
    }

    let w3w=[];
    if(event.offline_w3w_path){
      const {data:w3wBlob,error}=await supabase.storage.from("event-assets").download(event.offline_w3w_path);
      if(error)throw error;
      w3w=JSON.parse(await w3wBlob.text());
    }
    const {data:zones}=await supabase.from("event_zones").select("*").eq("event_id",S.eventId).eq("active",true);
    await saveOfflineEvent({eventId:S.eventId,savedAt:new Date().toISOString(),layers:offlineLayers,pois:pois||[],zones:zones||[],w3w});
    status.textContent=`Saved offline: ${offlineLayers.length} map layer${offlineLayers.length===1?"":"s"} + ${w3w.length.toLocaleString()} W3W squares.`;
  }catch(err){status.textContent=`Offline download failed: ${err.message}`;}
}

async function showFieldMap(incident){
  const holder=document.querySelector("#fieldMapHolder");
  holder.innerHTML=`<div id="fieldLayerName" class="small muted" style="margin-top:8px"></div><div id="fieldMap" style="height:420px;margin-top:6px;border-radius:10px;overflow:hidden"></div><div id="fieldMapReadout" class="small muted" style="margin-top:6px"></div>`;
  let m=null,url=null,w3wRows=[];
  const targetLayerId=incident.map_layer_id||null;
  try{
    if(navigator.onLine){
      let q=supabase.from("event_map_layers").select("*").eq("event_id",S.eventId).eq("status","published");
      q=targetLayerId?q.eq("id",targetLayerId):q.eq("is_default",true);
      const {data}=await q.limit(1).maybeSingle();
      if(data?.rendered_image_path){m=data;url=await storageSigned(m.rendered_image_path);}
    }
  }catch{}
  const offline=await getOfflineEvent(S.eventId).catch(()=>null);
  if(!m&&offline?.layers?.length){const item=offline.layers.find(x=>x.meta.id===targetLayerId)||offline.layers.find(x=>x.meta.is_default)||offline.layers[0];m=item.meta;url=URL.createObjectURL(item.mapBlob);w3wRows=offline.w3w||[];}else if(offline){w3wRows=offline.w3w||[];}
  if(!m||!url)return alert("No published map layer is available. Download the event package while connected.");
  document.querySelector("#fieldLayerName").textContent=`Map layer: ${m.name}${incident.zone_id?` · ${offline?.zones?.find(z=>z.id===incident.zone_id)?.name||""}`:""}`;
  const map=L.map("fieldMap",{crs:L.CRS.Simple,minZoom:-4,maxZoom:5,attributionControl:false});
  L.imageOverlay(url,[[0,0],[m.image_height,m.image_width]]).addTo(map);
  if(incident.map_x!=null&&incident.map_y!=null){const pt=pixelToLeaflet(incident.map_x,incident.map_y,m.image_height);L.marker(pt).addTo(map).bindPopup(`${esc(incident.incident_number)}<br>${esc(incident.landmark||"")}`).openPopup();map.setView(pt,0);}else map.fitBounds([[0,0],[m.image_height,m.image_width]]);
  if(m.georef_coefficients)map.on("click",async e=>{const px=leafletToPixel(e.latlng,m.image_height),geo=pixelToGeo(px.x,px.y,m.georef_coefficients);let words=localW3WForCoordinate(w3wRows,geo.lat,geo.lon);if(!words&&navigator.onLine){try{words=(await supabase.rpc("w3w_for_coordinate",{p_event_id:S.eventId,p_lat:geo.lat,p_lon:geo.lon})).data||null;}catch{}}document.querySelector("#fieldMapReadout").textContent=`${m.name} · ${words?`///${words} · `:""}${geo.lat.toFixed(6)}, ${geo.lon.toFixed(6)}`;});
}

async function leaveField(){
  if(S.fieldSession?.id)await supabase.rpc("field_end_session",{p_field_session_id:S.fieldSession.id});
  await supabase.auth.signOut();S.mode=null;reset();clearNavigationState();route();
}

/* ---------------- REALTIME / RESET ---------------- */

function subscribeDispatch(){
  const ch=supabase.channel(`event-${S.eventId}-${Date.now()}`)
    // Unit status changes are extremely frequent. Update only the matching unit
    // controls; never rebuild the CAD/map or destroy an incident form in progress.
    .on("postgres_changes",{event:"UPDATE",schema:"public",table:"units",filter:`event_id=eq.${S.eventId}`},payload=>{
      if(payload.new?.id && payload.new?.status){
        updateDispatcherUnitStatusUI(payload.new.id,payload.new.status);
      }
    })
    // A new/closed/edited incident changes the call board structurally, so reload.
    .on("postgres_changes",{event:"*",schema:"public",table:"incidents",filter:`event_id=eq.${S.eventId}`},()=>dispatchPage())
    // Assignment/unassignment changes the call/unit relationship and needs a
    // structural refresh. Ordinary crew status changes do NOT touch this table.
    .on("postgres_changes",{event:"*",schema:"public",table:"incident_units"},()=>dispatchPage())
    .subscribe();
  S.realtime.push(ch);
}
function subscribeField(unitId){
  // A field CAD screen should stay visually stable while a crew changes status.
  // Replace any previous field subscriptions, then update only the status badge
  // for unit row changes. Assignment/unassignment still performs a full refresh.
  S.realtime.forEach(ch=>supabase.removeChannel(ch));
  S.realtime=[];

  const ch=supabase.channel(`unit-${unitId}-${Date.now()}`)
    .on("postgres_changes",{event:"UPDATE",schema:"public",table:"units",filter:`id=eq.${unitId}`},payload=>{
      const status=payload.new?.status;
      if(status){
        if(S.fieldSession?.units)S.fieldSession.units.status=status;
        updateFieldUnitStatusUI(status);
      }
    })
    .on("postgres_changes",{event:"*",schema:"public",table:"incident_units",filter:`unit_id=eq.${unitId}`},()=>fieldUnitCad())
    .subscribe();

  S.realtime.push(ch);
}
function cleanupRealtime(){
  S.realtime.forEach(ch=>supabase.removeChannel(ch));S.realtime=[];
  if(S.map){try{S.map.remove()}catch{}}S.map=null;
}
function reset(){S.orgId=null;S.eventId=null;S.event=null;S.fieldSession=null;S.activeMapLayerId=null;}

init();
