import "./style.css";
import L from "leaflet";
import { supabase } from "./supabase.js";
import { renderMapBuilder } from "./mapBuilder.js";
import { pixelToGeo, pixelToLeaflet, leafletToPixel, geoToPixel, distanceMeters } from "./georef.js";
import { saveOfflineEvent, getOfflineEvent } from "./offlineStore.js";
import { renderEmsOps, renderEmsAdmin, renderTreatmentAreaFlow, loadFieldEmsState, fieldEmsPanelHtml, bindFieldEmsPanel, renderDispatchIncidentTreatmentPanel } from "./ems.js";
import { loadVenueChoices, applyVenueVersionToEvent, saveEventToVenueLibrary, renderVenueLibrary } from "./venueLibrary.js";

const app=document.querySelector("#app");
const S={
  mode:null,session:null,orgs:[],orgId:null,events:[],eventId:null,event:null,
  departments:[],units:[],incidents:[],pois:[],eventMap:null,mapLayers:[],zones:[],accessPoints:[],accessNodes:[],
  emsUnitConfigs:[],treatmentAreas:[],activeMapLayerId:null,map:null,realtime:[],
  fieldSession:null,currentLocation:null,isPlatformAdmin:false,callTimerInterval:null,
  unitLocations:[],unitLocationMarkers:new Map(),locationAgeInterval:null,
  locationWatchId:null,locationLastSentAt:0,locationLastSent:null,locationWriteInFlight:false,
  openIncidentId:null,openUnitId:null,incidentModalMode:null,
  dispatchLayout:null,
  dispatchDepartmentIds:[],
  commandDepartmentIds:[],
  commandDisplayMode:"calls",
  commandActiveMapLayerId:null,
  commandMap:null,
  commandMapGeneration:0,
  commandIncidentLayer:null,
  commandUnitLayer:null,
  commandRefreshTimer:null,
  commandClockInterval:null,
  mapPickMode:null,
  pendingIncidentDraft:null
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



const DISPATCH_LAYOUT_DEFAULTS={
  mode:"classic",
  callsSize:300,
  unitsSize:310,
  bottomSize:250
};

function dispatchLayoutKey(){
  return `commcenter-dispatch-layout:${S.session?.user?.id||"staff"}:${S.eventId||"event"}`;
}

function normalizeDispatchLayout(value){
  const allowedModes=new Set([
    "classic",
    "units-left-calls-bottom",
    "calls-left-units-bottom"
  ]);

  const input=value&&typeof value==="object"?value:{};
  return {
    mode:allowedModes.has(input.mode)?input.mode:DISPATCH_LAYOUT_DEFAULTS.mode,
    callsSize:Math.max(220,Math.min(520,Number(input.callsSize)||DISPATCH_LAYOUT_DEFAULTS.callsSize)),
    unitsSize:Math.max(220,Math.min(520,Number(input.unitsSize)||DISPATCH_LAYOUT_DEFAULTS.unitsSize)),
    bottomSize:Math.max(170,Math.min(480,Number(input.bottomSize)||DISPATCH_LAYOUT_DEFAULTS.bottomSize))
  };
}

function loadDispatchLayout(){
  let saved=null;
  try{
    const raw=localStorage.getItem(dispatchLayoutKey());
    if(raw)saved=JSON.parse(raw);
  }catch{}
  S.dispatchLayout=normalizeDispatchLayout(saved);
  return S.dispatchLayout;
}

function saveDispatchLayout(){
  S.dispatchLayout=normalizeDispatchLayout(S.dispatchLayout);
  try{localStorage.setItem(dispatchLayoutKey(),JSON.stringify(S.dispatchLayout));}catch{}
}

function dispatchLayoutModeLabel(mode){
  return ({
    classic:"Calls Left · Units Right",
    "units-left-calls-bottom":"Units Left · Calls Bottom",
    "calls-left-units-bottom":"Calls Left · Units Bottom"
  })[mode]||"Dispatcher Layout";
}

function dispatchLayoutDescription(mode){
  return ({
    classic:"Traditional three-column CAD view with the map centered between active calls and units.",
    "units-left-calls-bottom":"Keeps units visible on the left, puts active calls along the bottom, and gives the map the remaining workspace.",
    "calls-left-units-bottom":"Keeps active calls on the left, puts units along the bottom, and gives the map the remaining workspace."
  })[mode]||"";
}

function applyDispatchLayoutToDom({invalidate=true}={}){
  const grid=document.querySelector("#dispatchWorkspace");
  if(!grid)return;

  const prefs=normalizeDispatchLayout(S.dispatchLayout);
  S.dispatchLayout=prefs;

  grid.classList.remove(
    "layout-classic",
    "layout-units-left-calls-bottom",
    "layout-calls-left-units-bottom"
  );
  grid.classList.add(`layout-${prefs.mode}`);
  grid.style.setProperty("--dispatch-calls-size",`${prefs.callsSize}px`);
  grid.style.setProperty("--dispatch-units-size",`${prefs.unitsSize}px`);
  grid.style.setProperty("--dispatch-bottom-size",`${prefs.bottomSize}px`);

  const label=document.querySelector("#layoutButton");
  if(label)label.textContent=`Layout: ${dispatchLayoutModeLabel(prefs.mode)}`;

  if(invalidate){
    requestAnimationFrame(()=>{
      S.map?.invalidateSize?.({pan:false});
    });
  }
}

function bindDispatchResizers(){
  const grid=document.querySelector("#dispatchWorkspace");
  if(!grid)return;

  const begin=(handle,event)=>{
    if(window.matchMedia("(max-width: 980px)").matches)return;
    event.preventDefault();

    const mode=S.dispatchLayout?.mode||"classic";
    const rect=grid.getBoundingClientRect();
    const pointerId=event.pointerId;
    handle.setPointerCapture?.(pointerId);
    document.body.classList.add("dispatch-resizing");

    let frame=null;
    const update=e=>{
      if(frame)return;
      frame=requestAnimationFrame(()=>{
        frame=null;

        if(handle.dataset.resize==="a"){
          if(mode==="units-left-calls-bottom"){
            S.dispatchLayout.unitsSize=Math.max(220,Math.min(520,e.clientX-rect.left));
          }else{
            S.dispatchLayout.callsSize=Math.max(220,Math.min(520,e.clientX-rect.left));
          }
        }else{
          if(mode==="classic"){
            S.dispatchLayout.unitsSize=Math.max(220,Math.min(520,rect.right-e.clientX));
          }else{
            S.dispatchLayout.bottomSize=Math.max(170,Math.min(480,rect.bottom-e.clientY));
          }
        }

        applyDispatchLayoutToDom({invalidate:false});
      });
    };

    const finish=()=>{
      if(frame){
        cancelAnimationFrame(frame);
        frame=null;
      }
      handle.removeEventListener("pointermove",update);
      handle.removeEventListener("pointerup",finish);
      handle.removeEventListener("pointercancel",finish);
      document.body.classList.remove("dispatch-resizing");
      saveDispatchLayout();
      S.map?.invalidateSize?.({pan:false});
    };

    handle.addEventListener("pointermove",update);
    handle.addEventListener("pointerup",finish);
    handle.addEventListener("pointercancel",finish);
  };

  document.querySelectorAll("#dispatchWorkspace .dispatch-resizer").forEach(handle=>{
    handle.onpointerdown=e=>begin(handle,e);
  });
}

function renderDispatchLayoutModal(){
  const prefs=normalizeDispatchLayout(S.dispatchLayout||loadDispatchLayout());
  S.incidentModalMode="layout";
  const content=openIncidentModalShell();

  content.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">DISPATCH WORKSPACE</div>
      <div class="incident-modal-title-row"><h2 id="incidentModalTitle">Configure Layout</h2></div>
      <div class="incident-modal-nature">Choose a workspace arrangement and resize the panels to fit this dispatcher.</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close layout settings">×</button>
  </div>

  <div class="dispatch-layout-modal stack">
    <div class="dispatch-layout-presets">
      ${[
        ["classic","Calls Left · Units Right","Three-column CAD"],
        ["units-left-calls-bottom","Units Left · Calls Bottom","Map-focused operations"],
        ["calls-left-units-bottom","Calls Left · Units Bottom","Call-focused operations"]
      ].map(([mode,title,subtitle])=>`
        <button class="dispatch-layout-card ${prefs.mode===mode?"active":""}" data-layout-mode="${mode}">
          <span class="dispatch-layout-preview preview-${mode}">
            <i class="preview-calls"></i><i class="preview-map"></i><i class="preview-units"></i>
          </span>
          <strong>${esc(title)}</strong>
          <span>${esc(subtitle)}</span>
        </button>
      `).join("")}
    </div>

    <div class="card dispatch-layout-sizing">
      <div class="row">
        <div>
          <div class="section-title">Panel Sizes</div>
          <div class="small muted">You can also drag the divider handles directly on the CAD board.</div>
        </div>
        <button class="btn secondary" id="resetDispatchLayout">Reset Sizes</button>
      </div>

      <label>Active calls panel <span id="callsSizeValue">${Math.round(prefs.callsSize)} px</span></label>
      <input type="range" id="callsSizeRange" min="220" max="520" step="10" value="${Math.round(prefs.callsSize)}">

      <label>Units panel <span id="unitsSizeValue">${Math.round(prefs.unitsSize)} px</span></label>
      <input type="range" id="unitsSizeRange" min="220" max="520" step="10" value="${Math.round(prefs.unitsSize)}">

      <label>Bottom panel height <span id="bottomSizeValue">${Math.round(prefs.bottomSize)} px</span></label>
      <input type="range" id="bottomSizeRange" min="170" max="480" step="10" value="${Math.round(prefs.bottomSize)}">
    </div>

    <div class="notice">
      <strong id="layoutModeName">${esc(dispatchLayoutModeLabel(prefs.mode))}</strong><br>
      <span id="layoutModeDescription">${esc(dispatchLayoutDescription(prefs.mode))}</span>
    </div>

    <div class="small muted">Layout preferences are saved for this user, event, and browser. They do not change another dispatcher's workstation.</div>
  </div>

  <div class="incident-modal-footer">
    <button class="btn secondary" id="cancelLayoutSettings">Close</button>
    <button class="btn" id="saveLayoutSettings">Save Layout</button>
  </div>`;

  const chooseMode=mode=>{
    S.dispatchLayout=normalizeDispatchLayout({...S.dispatchLayout,mode});
    document.querySelectorAll("[data-layout-mode]").forEach(btn=>btn.classList.toggle("active",btn.dataset.layoutMode===mode));
    document.querySelector("#layoutModeName").textContent=dispatchLayoutModeLabel(mode);
    document.querySelector("#layoutModeDescription").textContent=dispatchLayoutDescription(mode);
    applyDispatchLayoutToDom();
  };

  document.querySelectorAll("[data-layout-mode]").forEach(btn=>btn.onclick=()=>chooseMode(btn.dataset.layoutMode));

  const bindRange=(id,key,labelId)=>{
    const input=document.querySelector(id);
    input.oninput=()=>{
      S.dispatchLayout=normalizeDispatchLayout({...S.dispatchLayout,[key]:Number(input.value)});
      document.querySelector(labelId).textContent=`${Math.round(S.dispatchLayout[key])} px`;
      applyDispatchLayoutToDom();
    };
  };
  bindRange("#callsSizeRange","callsSize","#callsSizeValue");
  bindRange("#unitsSizeRange","unitsSize","#unitsSizeValue");
  bindRange("#bottomSizeRange","bottomSize","#bottomSizeValue");

  document.querySelector("#resetDispatchLayout").onclick=()=>{
    S.dispatchLayout=normalizeDispatchLayout({...DISPATCH_LAYOUT_DEFAULTS,mode:S.dispatchLayout?.mode||"classic"});
    document.querySelector("#callsSizeRange").value=S.dispatchLayout.callsSize;
    document.querySelector("#unitsSizeRange").value=S.dispatchLayout.unitsSize;
    document.querySelector("#bottomSizeRange").value=S.dispatchLayout.bottomSize;
    document.querySelector("#callsSizeValue").textContent=`${S.dispatchLayout.callsSize} px`;
    document.querySelector("#unitsSizeValue").textContent=`${S.dispatchLayout.unitsSize} px`;
    document.querySelector("#bottomSizeValue").textContent=`${S.dispatchLayout.bottomSize} px`;
    applyDispatchLayoutToDom();
  };

  const close=()=>closeIncidentModal();
  document.querySelector("#closeIncidentModal").onclick=close;
  document.querySelector("#cancelLayoutSettings").onclick=close;
  document.querySelector("#saveLayoutSettings").onclick=()=>{
    saveDispatchLayout();
    applyDispatchLayoutToDom();
    closeIncidentModal();
  };
}

function dispatchScopeKey(){
  return `commcenter-dispatch-scope:${S.session?.user?.id||"staff"}:${S.eventId||"event"}`;
}
function commandDisplayKey(){
  return `commcenter-command-display:${S.session?.user?.id||"staff"}:${S.eventId||"event"}`;
}
function normalizeDepartmentSelection(ids){
  const valid=new Set(S.departments.map(d=>d.id));
  return [...new Set((Array.isArray(ids)?ids:[]).filter(id=>valid.has(id)))];
}
function loadDispatchScope(){
  let ids=[];
  try{
    const raw=localStorage.getItem(dispatchScopeKey());
    if(raw)ids=JSON.parse(raw);
  }catch{}
  ids=normalizeDepartmentSelection(ids);
  S.dispatchDepartmentIds=ids.length?ids:S.departments.map(d=>d.id);
  saveDispatchScope();
}
function saveDispatchScope(){
  try{localStorage.setItem(dispatchScopeKey(),JSON.stringify(S.dispatchDepartmentIds));}catch{}
}
function dispatchScopeDepartments(){
  const selected=new Set(S.dispatchDepartmentIds);
  return S.departments.filter(d=>selected.has(d.id));
}
function incidentDepartmentIds(i){
  return (i.incident_departments||[]).map(link=>link.department_id).filter(Boolean);
}
function incidentMatchesDepartments(i,departmentIds){
  const selected=new Set(departmentIds||[]);
  return selected.size>0&&incidentDepartmentIds(i).some(id=>selected.has(id));
}
function incidentInDispatchScope(i){
  return incidentMatchesDepartments(i,S.dispatchDepartmentIds);
}
function unitInDispatchScope(u){
  return S.dispatchDepartmentIds.includes(u.department_id);
}
function scopeLabel(ids=S.dispatchDepartmentIds){
  const selected=S.departments.filter(d=>ids.includes(d.id));
  if(!selected.length)return "None";
  if(selected.length===S.departments.length)return "All Departments";
  return selected.map(d=>d.short_name||d.name).join(" + ");
}
function loadCommandDisplayPreferences(){
  let saved=null;
  try{
    const raw=localStorage.getItem(commandDisplayKey());
    if(raw)saved=JSON.parse(raw);
  }catch{}
  const selected=normalizeDepartmentSelection(saved?.departmentIds||S.dispatchDepartmentIds);
  S.commandDepartmentIds=selected.length?selected:S.departments.map(d=>d.id);
  S.commandDisplayMode=["calls","map","split"].includes(saved?.mode)?saved.mode:"calls";
  S.commandActiveMapLayerId=
    S.mapLayers.some(l=>l.id===saved?.mapLayerId&&l.status==="published")
      ? saved.mapLayerId
      : (S.activeMapLayerId||S.mapLayers.find(l=>l.is_default&&l.status==="published")?.id||S.mapLayers.find(l=>l.status==="published")?.id||null);
}
function saveCommandDisplayPreferences(){
  try{
    localStorage.setItem(commandDisplayKey(),JSON.stringify({
      departmentIds:S.commandDepartmentIds,
      mode:S.commandDisplayMode,
      mapLayerId:S.commandActiveMapLayerId
    }));
  }catch{}
}

function commandViewRequested(){
  try{return new URLSearchParams(window.location.search).get("view")==="command";}catch{return false;}
}
function setCommandViewUrl(active){
  try{
    const url=new URL(window.location.href);
    if(active)url.searchParams.set("view","command");
    else url.searchParams.delete("view");
    history.replaceState(null,"",url);
  }catch{}
}

function renderDispatchScopeModal(){
  const content=openIncidentModalShell();
  S.incidentModalMode="scope";
  content.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">DISPATCH WORKSTATION</div>
      <div class="incident-modal-title-row"><h2 id="incidentModalTitle">Dispatch Scope</h2></div>
      <div class="incident-modal-nature">Choose the department(s) this console is actively dispatching.</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close dispatch scope">×</button>
  </div>
  <div class="dispatch-scope-modal">
    <p class="muted">This filters the active-call board, unit board, dispatch map, and the default departments on every new call. Unified dispatchers can select multiple departments.</p>
    <div class="dispatch-scope-grid">
      ${S.departments.map(d=>`<label class="status-select-option">
        <input type="checkbox" name="dispatchScopeDept" value="${d.id}" ${S.dispatchDepartmentIds.includes(d.id)?"checked":""}>
        <span><strong>${esc(d.name)}</strong>${d.short_name?`<br><span class="small muted">${esc(d.short_name)}</span>`:""}</span>
      </label>`).join("")}
    </div>
  </div>
  <div class="incident-modal-footer">
    <button class="btn secondary" id="scopeAll">Select All</button>
    <button class="btn secondary" id="scopeCancel">Cancel</button>
    <button class="btn" id="scopeSave">Use Selected Departments</button>
  </div>`;
  document.querySelector("#closeIncidentModal").onclick=()=>closeIncidentModal();
  document.querySelector("#scopeCancel").onclick=()=>closeIncidentModal();
  document.querySelector("#scopeAll").onclick=()=>document.querySelectorAll('input[name="dispatchScopeDept"]').forEach(el=>el.checked=true);
  document.querySelector("#scopeSave").onclick=()=>{
    const ids=[...document.querySelectorAll('input[name="dispatchScopeDept"]:checked')].map(el=>el.value);
    if(!ids.length)return alert("Select at least one department.");
    S.dispatchDepartmentIds=normalizeDepartmentSelection(ids);
    saveDispatchScope();
    closeIncidentModal();
    refreshDispatchBoards();
    updateDispatchScopeUi();
    setupDispatchMap();
  };
}
function updateDispatchScopeUi(){
  const button=document.querySelector("#dispatchScopeBtn");
  if(button)button.textContent=`Dispatching: ${scopeLabel()}`;
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
    <div class="center">
      <form class="card stack" id="staffLoginForm">
        <h2>Dispatcher / Admin Login</h2>
        <div><label for="email">Email</label><input id="email" name="email" type="email" autocomplete="email" required></div>
        <div><label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password" required></div>
        <button class="btn" id="login" type="submit">Sign in</button>
        <button class="btn secondary" id="back" type="button">Back</button>
        <div id="loginError" class="small muted" role="alert" aria-live="polite"></div>
      </form>
    </div></div>`;

  document.querySelector("#back").onclick=()=>{S.mode=null;route();};

  document.querySelector("#staffLoginForm").addEventListener("submit",async e=>{
    e.preventDefault();

    const email=document.querySelector("#email").value.trim();
    const password=document.querySelector("#password").value;
    const button=document.querySelector("#login");
    const errorHost=document.querySelector("#loginError");

    errorHost.textContent="";
    button.disabled=true;
    button.textContent="Signing in…";

    const {error}=await supabase.auth.signInWithPassword({email,password});

    if(error){
      errorHost.textContent=error.message;
      button.disabled=false;
      button.textContent="Sign in";
      return;
    }

    route();
  });

  setTimeout(()=>document.querySelector("#email")?.focus(),0);
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
  return commandViewRequested()?commandDisplayPage():dispatchPage();
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
      <div><label>Company / organization name</label><input id="orgName" placeholder="Organization name"></div>
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
  document.querySelectorAll("[data-event]").forEach(b=>b.onclick=()=>{S.eventId=b.dataset.event;saveNavigationState();commandViewRequested()?commandDisplayPage():dispatchPage();});
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
      <div><label>User email</label><input id="memberEmail" type="email" placeholder="Email address"></div>
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
      <div><label>Event name</label><input id="eventName" placeholder="Event name"></div>
      <div><label>Event ID / field code</label><input id="eventCode" placeholder="Event code"></div>
      <div><label>4-digit field PIN</label><input id="fieldPin" inputmode="numeric" maxlength="4" placeholder="••••"></div>
      <div><label>Incident prefix</label><input id="prefix" placeholder="Event code"></div>

      <div>
        <label>Venue / Map Setup</label>
        <select id="venueVersion">
          <option value="">Start with a blank event map</option>
          ${venues.map(v=>`<option value="${v.version_id}" ${v.version_id===preselectedVersionId?"selected":""}>${esc(v.venue_name)} · v${v.version_number}${v.address?` · ${esc(v.address)}`:""}</option>`).join("")}
        </select>
        <div class="small muted" style="margin-top:5px">Selecting a venue copies its published map layers, calibration, zones, POIs, aliases, and vertical access points into this event as a snapshot.</div>
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
    accessNodesRes,
    unitLocationsRes,
    emsUnitConfigsRes,
    treatmentAreasRes
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
    supabase.from("venue_access_point_nodes").select("*"),
    supabase.from("unit_locations").select("*").eq("event_id",S.eventId),
    supabase.from("ems_unit_config").select("*"),
    supabase.from("ems_treatment_areas").select("*").eq("event_id",S.eventId).eq("active",true).order("name")
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
    accessNodes: accessNodesRes,
    unitLocations: unitLocationsRes,
    emsUnitConfigs: emsUnitConfigsRes,
    treatmentAreas: treatmentAreasRes
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
  S.unitLocations=unitLocationsRes.data||[];
  S.emsUnitConfigs=emsUnitConfigsRes.data||[];
  S.treatmentAreas=treatmentAreasRes.data||[];
  const apIds=new Set(S.accessPoints.map(a=>a.id));
  S.accessNodes=(accessNodesRes.data||[]).filter(n=>apIds.has(n.access_point_id));
  const preferred=S.mapLayers.find(l=>l.id===S.activeMapLayerId);
  const fallback=S.mapLayers.find(l=>l.is_default&&l.status==="published")||S.mapLayers.find(l=>l.status==="published")||S.mapLayers[0]||null;
  S.activeMapLayerId=(preferred||fallback)?.id||null;
  loadDispatchScope();
}

function activeMapLayer(){return S.mapLayers.find(l=>l.id===S.activeMapLayerId)||null;}
function zoneName(id){return S.zones.find(z=>z.id===id)?.name||"";}
function layerName(id){return S.mapLayers.find(l=>l.id===id)?.name||"";}



function poiMapIcon(){
  return L.divIcon({
    className:"cc-leaflet-div-icon",
    html:`<span class="cc-map-pin cc-poi-pin" aria-hidden="true"><span class="cc-map-pin-dot"></span></span>`,
    iconSize:[26,32],
    iconAnchor:[13,31],
    tooltipAnchor:[0,-28]
  });
}

function fieldIncidentMapIcon(){
  return L.divIcon({
    className:"cc-leaflet-div-icon",
    html:`<span class="cc-map-pin cc-field-incident-pin" aria-hidden="true"><span class="cc-map-pin-dot"></span></span>`,
    iconSize:[28,34],
    iconAnchor:[14,33],
    popupAnchor:[0,-30]
  });
}

function poiSearchText(p){
  return [
    p.name,
    p.category,
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
      `<strong>${esc(p.name)}</strong><br>${esc(layerName(p.map_layer_id)||"")}${p.zone_id?` · ${esc(zoneName(p.zone_id))}`:""}`
    ).openOn(S.map);
  }
}


function showPoiFinder(){
  S.openIncidentId=null;
  S.openUnitId=null;
  S.incidentModalMode="poi-search";

  const detail=openIncidentModalShell();
  detail.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">DISPATCH MAP</div>
      <div class="incident-modal-title-row"><h2 id="incidentModalTitle">Find POI</h2><span class="badge">${S.pois.length} locations</span></div>
      <div class="incident-modal-nature">Search the active event map.</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close POI finder">×</button>
  </div>

  <div class="poi-finder-modal stack" data-dispatch-editor="poi-search">
    <div class="row">
      <label>Search name, alias, category, level, or zone</label>
      <button class="btn secondary" id="addPoiFromMap">+ Add POI from Map</button>
    </div>
    <input id="dispatcherPoiSearch" autocomplete="off" placeholder="Search POIs">
    <div id="dispatcherPoiResults" class="poi-search-results"></div>
    <div id="dispatcherPoiSelected" class="small muted">Start typing to search event POIs.</div>
  </div>`;

  document.querySelector("#closeIncidentModal").onclick=()=>closeIncidentModal();
  document.querySelector("#addPoiFromMap").onclick=()=>startPoiPlacement();

  bindPoiSearch({
    inputId:"dispatcherPoiSearch",
    resultsId:"dispatcherPoiResults",
    onSelect:async p=>{
      document.querySelector("#dispatcherPoiSelected").innerHTML=`
        <div class="poi-selected-card">
          <strong>${esc(p.name)}</strong><br>
          ${esc([p.category,layerName(p.map_layer_id),p.zone_id?zoneName(p.zone_id):""].filter(Boolean).join(" · "))}
          ${(p.poi_aliases||[]).length?`<br><span class="muted">Aliases: ${esc((p.poi_aliases||[]).map(a=>a.alias).join(", "))}</span>`:""}
          <div class="grid2" style="margin-top:10px">
            <button class="btn secondary" id="showPoiOnMap">Show on Map</button>
            <button class="btn" id="createAtPoi">Create Incident Here</button>
          </div>
        </div>`;
      document.querySelector("#showPoiOnMap").onclick=async()=>{
        await focusPoiOnMap(p);
        closeIncidentModal();
      };
      document.querySelector("#createAtPoi").onclick=async()=>{
        await focusPoiOnMap(p);
        incidentForm(poiLocationObject(p));
      };
    }
  });

  setTimeout(()=>document.querySelector("#dispatcherPoiSearch")?.focus(),0);
}


function showMapPickBanner(message){
  const banner=document.querySelector("#mapPickBanner");
  if(!banner)return;
  banner.innerHTML=`<strong>${esc(message)}</strong><button class="btn secondary" id="cancelMapPick">Cancel</button>`;
  banner.classList.add("active");
  document.querySelector("#cancelMapPick").onclick=()=>{
    S.mapPickMode=null;
    S.pendingIncidentDraft=null;
    hideMapPickBanner();
  };
}
function hideMapPickBanner(){
  const banner=document.querySelector("#mapPickBanner");
  if(!banner)return;
  banner.classList.remove("active");
  banner.innerHTML="";
}
function startPoiPlacement(){
  const layer=activeMapLayer();
  if(!layer?.georef_coefficients)return alert("The selected map layer must be calibrated before Dispatch can place a POI from a map click.");
  closeIncidentModal();
  S.mapPickMode="poi";
  S.pendingIncidentDraft=null;
  showMapPickBanner("Click the event map where the new POI should be placed.");
}
function collectNewIncidentDraft(){
  const modal=document.querySelector("[data-incident-modal-mode='new']");
  if(!modal)return null;
  return {
    callType:document.querySelector("#callType")?.value||"",
    priority:document.querySelector("#priority")?.value||"Standard",
    landmark:document.querySelector("#landmark")?.value||"",
    notes:document.querySelector("#notes")?.value||"",
    departmentIds:[...document.querySelectorAll('input[name="dept"]:checked')].map(x=>x.value),
    initialUnitIds:[...document.querySelectorAll('input[name="initialUnit"]:checked')].map(x=>x.value)
  };
}
function startIncidentMapPlacement(){
  const layer=activeMapLayer();
  if(!layer?.georef_coefficients)return alert("The selected map layer must be calibrated before a location can be selected from the map.");
  S.pendingIncidentDraft=collectNewIncidentDraft();
  S.mapPickMode="incident";
  closeIncidentModal();
  showMapPickBanner("Click the map to set the incident location. Your unfinished call form is preserved.");
}
async function dispatcherPoiForm(loc,{returnToFinder=false}={}){
  if(!loc)return;
  S.incidentModalMode="poi-create";
  const content=openIncidentModalShell();
  const zones=S.zones.filter(z=>!loc.map_layer_id||z.map_layer_id===loc.map_layer_id);

  content.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">DISPATCH MAP</div>
      <div class="incident-modal-title-row"><h2 id="incidentModalTitle">Add POI</h2></div>
      <div class="incident-modal-nature">Save an event location without opening Event Admin.</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close POI form">×</button>
  </div>
  <div class="dispatcher-poi-form stack">
    <div class="grid2">
      <div><label>POI Name</label><input id="dispatchPoiName" autofocus placeholder="POI name"></div>
      <div><label>Category</label><select id="dispatchPoiCategory">
        <option>Medical</option><option>Command</option><option>Security</option><option>Gate</option>
        <option>Portal</option><option>Seating Section</option><option>Concession</option><option>Restroom</option>
        <option>Production</option><option>Staging</option><option>Other</option>
      </select></div>
    </div>
    <div><label>Zone</label><select id="dispatchPoiZone"><option value="">No zone</option>${zones.map(z=>`<option value="${z.id}">${esc(z.name)}</option>`).join("")}</select></div>
    <div><label>Aliases</label><input id="dispatchPoiAliases" placeholder="Comma-separated aliases"></div>
    <div><label>Operational Notes</label><textarea id="dispatchPoiNotes" rows="4" placeholder="Optional notes"></textarea></div>
    <div class="notice">
      <strong>${esc(layerName(loc.map_layer_id)||"Event Map")}</strong><br>
      <span class="small mono">${Number(loc.latitude).toFixed(6)}, ${Number(loc.longitude).toFixed(6)}</span>
    </div>
    <div class="small muted">Dispatcher-created POIs are event-only. They do not automatically change the reusable organization Venue Library.</div>
  </div>
  <div class="incident-modal-footer">
    <button class="btn secondary" id="cancelDispatchPoi">Cancel</button>
    <button class="btn" id="saveDispatchPoi">Save POI</button>
  </div>`;

  const cancel=()=>{
    closeIncidentModal();
    if(returnToFinder)showPoiFinder();
  };
  document.querySelector("#closeIncidentModal").onclick=cancel;
  document.querySelector("#cancelDispatchPoi").onclick=cancel;

  document.querySelector("#saveDispatchPoi").onclick=async()=>{
    const name=document.querySelector("#dispatchPoiName").value.trim();
    if(!name)return alert("Enter a POI name.");
    const aliases=document.querySelector("#dispatchPoiAliases").value.split(",").map(x=>x.trim()).filter(Boolean);
    const button=document.querySelector("#saveDispatchPoi");
    button.disabled=true;button.textContent="Saving…";

    const {data,error}=await supabase.rpc("dispatcher_create_poi_v2",{
      p_event_id:S.eventId,
      p_name:name,
      p_category:document.querySelector("#dispatchPoiCategory").value,
      p_map_layer_id:loc.map_layer_id||S.activeMapLayerId||null,
      p_zone_id:document.querySelector("#dispatchPoiZone").value||null,
      p_latitude:loc.latitude,
      p_longitude:loc.longitude,
      p_map_x:loc.map_x,
      p_map_y:loc.map_y,
      p_notes:document.querySelector("#dispatchPoiNotes").value.trim()||null,
      p_aliases:aliases
    });
    if(error){
      button.disabled=false;button.textContent="Save POI";
      return alert(error.message);
    }

    const {data:poi,error:fetchError}=await supabase.from("event_pois").select("*,poi_aliases(alias)").eq("id",data).single();
    if(fetchError){
      await loadEventOps();
    }else{
      const existing=S.pois.findIndex(p=>p.id===poi.id);
      if(existing>=0)S.pois[existing]=poi;else S.pois.push(poi);
      S.pois.sort((a,b)=>a.name.localeCompare(b.name));
    }

    closeIncidentModal();
    await setupDispatchMap();
    if(returnToFinder)showPoiFinder();
  };
}


async function handleRealtimePoiInsert(payload){
  const id=payload?.new?.id;
  if(!id)return;
  // Alias rows may be inserted immediately after the POI row. A short delay
  // lets the search cache pick them up as part of the same operational action.
  await new Promise(resolve=>setTimeout(resolve,150));
  const {data,error}=await supabase.from("event_pois").select("*,poi_aliases(alias)").eq("id",id).maybeSingle();
  if(error||!data)return;

  const index=S.pois.findIndex(p=>p.id===data.id);
  if(index>=0)S.pois[index]=data;else S.pois.push(data);
  S.pois.sort((a,b)=>a.name.localeCompare(b.name));

  const layer=activeMapLayer();
  if(S.map&&layer&&data.map_layer_id===layer.id&&data.map_x!=null&&data.map_y!=null){
    L.marker(pixelToLeaflet(data.map_x,data.map_y,layer.image_height),{icon:poiMapIcon()})
      .addTo(S.map)
      .bindTooltip(data.name,{direction:"top",offset:[0,-4]});
  }

  const count=S.incidentModalMode==="poi-search"
    ? document.querySelector("#incidentModal .incident-modal-title-row .badge")
    : document.querySelector('[data-dispatch-editor="poi-search"] .badge');
  if(count)count.textContent=`${S.pois.length} locations`;
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
    loadDispatchLayout();
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
    <div
      class="cad-grid dispatch-workspace layout-${esc(S.dispatchLayout.mode)}"
      id="dispatchWorkspace"
      style="--dispatch-calls-size:${Math.round(S.dispatchLayout.callsSize)}px;--dispatch-units-size:${Math.round(S.dispatchLayout.unitsSize)}px;--dispatch-bottom-size:${Math.round(S.dispatchLayout.bottomSize)}px"
    >
      <aside class="panel calls-panel">
        <button class="btn block" id="newIncident">+ New Incident</button>
        <button class="btn secondary block dispatch-scope-button" id="dispatchScopeBtn">Dispatching: ${esc(scopeLabel())}</button>
        <div class="section-title">Active incidents</div><div id="incidentList">${incidentList()}</div>
      </aside>

      <div class="dispatch-resizer dispatch-resizer-a" data-resize="a" aria-hidden="true"></div>

      <div class="map-wrap map-panel">
        <div class="map-level-toolbar"><span class="section-title">Map Layer</span><select id="dispatchLayerSelect">${S.mapLayers.filter(l=>l.status==="published").map(l=>`<option value="${l.id}" ${l.id===S.activeMapLayerId?"selected":""}>${esc(l.name)}${l.level_code?` · ${esc(l.level_code)}`:""}</option>`).join("")}</select></div>
        <div class="map-pick-banner" id="mapPickBanner"></div>
        <div id="map"></div>
      </div>

      <div class="dispatch-resizer dispatch-resizer-b" data-resize="b" aria-hidden="true"></div>

      <aside class="panel units-panel">
        <div class="row"><div><div class="section-title">Units</div><div class="small muted">Select a unit to open controls.</div></div></div>
        <div id="unitList">${unitList()}</div>
      </aside>
    </div></div>`;
  document.querySelector("#topActions").innerHTML=`
    <button class="btn secondary" id="poiFinderBtn">Find POI</button>
    <button class="btn secondary" id="addPoiBtn">Add POI</button>
    <button class="btn secondary" id="commandDisplayBtn">Command Display</button>
    <button class="btn secondary" id="layoutButton">Layout: ${esc(dispatchLayoutModeLabel(S.dispatchLayout.mode))}</button>
    <button class="btn secondary" id="emsOpsBtn">EMS Ops</button>
    <button class="btn secondary" id="adminBtn">Event Admin</button>
    <button class="btn secondary" id="reportsBtn">Reports</button>
    <button class="btn secondary" id="eventsBtn">Events</button>
    <button class="btn secondary" id="logoutBtn">Sign out</button>`;
  document.querySelector("#poiFinderBtn").onclick=()=>showPoiFinder();
  document.querySelector("#addPoiBtn").onclick=()=>startPoiPlacement();
  document.querySelector("#commandDisplayBtn").onclick=()=>commandDisplayPage();
  document.querySelector("#layoutButton").onclick=()=>renderDispatchLayoutModal();
  document.querySelector("#emsOpsBtn").onclick=()=>renderEmsOps(app,{eventId:S.eventId,event:S.event,header,onBack:()=>dispatchPage(),onAdmin:()=>eventAdmin("ems")});
  document.querySelector("#adminBtn").onclick=()=>eventAdmin();
  document.querySelector("#reportsBtn").onclick=()=>reportsPage();
  document.querySelector("#eventsBtn").onclick=()=>{closeIncidentModal();S.eventId=null;staffFlow();};
  document.querySelector("#logoutBtn").onclick=async()=>{closeIncidentModal();await supabase.auth.signOut();S.mode=null;reset();clearNavigationState();route();};
  document.querySelector("#newIncident").onclick=()=>incidentForm(null);
  document.querySelector("#dispatchScopeBtn").onclick=()=>renderDispatchScopeModal();
  document.querySelector("#dispatchLayerSelect")?.addEventListener("change",e=>{S.activeMapLayerId=e.target.value;saveNavigationState();setupDispatchMap();});
  bindIncidentClicks();
  applyDispatchLayoutToDom({invalidate:false});
  bindDispatchResizers();
  ensureCallTimerTicker();
  ensureLocationAgeTicker();
  await setupDispatchMap();
  subscribeDispatch();
}



function locationAgeSeconds(location){
  if(!location?.updated_at)return Infinity;
  return Math.max(0,Math.floor((Date.now()-new Date(location.updated_at).getTime())/1000));
}

function locationAgeLabel(location){
  const seconds=locationAgeSeconds(location);
  if(!Number.isFinite(seconds))return "No GPS";
  if(seconds<10)return "GPS now";
  if(seconds<60)return `GPS ${seconds}s`;
  if(seconds<3600)return `GPS ${Math.floor(seconds/60)}m`;
  return `GPS ${Math.floor(seconds/3600)}h`;
}

function locationFreshness(location){
  const seconds=locationAgeSeconds(location);
  if(seconds<=30)return "live";
  if(seconds<=300)return "stale";
  return "expired";
}

function unitLocation(unitId){
  return S.unitLocations.find(l=>l.unit_id===unitId)||null;
}

function unitLocationLayerId(unit){
  if(unit?.current_map_layer_id)return unit.current_map_layer_id;
  return S.mapLayers.find(l=>l.is_default&&l.status==="published")?.id
    || S.mapLayers.find(l=>l.status==="published")?.id
    || null;
}

function unitLocationTooltip(unit,location){
  const age=locationAgeLabel(location);
  const accuracy=location.accuracy_m!=null?` · ±${Math.round(location.accuracy_m)}m`:"";
  const layer=unitLocationLayerId(unit);
  return `<strong>${esc(unit.name)}</strong><br>${esc(String(unit.status||"").replaceAll("_"," "))}<br>${esc(age)}${esc(accuracy)}${layer?`<br>${esc(layerName(layer))}`:""}`;
}

function removeUnitLocationMarker(unitId){
  const entry=S.unitLocationMarkers.get(unitId);
  if(entry?.marker&&S.map){
    try{S.map.removeLayer(entry.marker);}catch{}
  }
  S.unitLocationMarkers.delete(unitId);
}

function renderUnitLocationMarker(unitId){
  if(!S.map)return;
  removeUnitLocationMarker(unitId);

  const unit=S.units.find(u=>u.id===unitId);
  const location=unitLocation(unitId);
  const layer=activeMapLayer();
  if(!unit||!location||!layer?.georef_coefficients)return;

  const freshness=locationFreshness(location);
  if(freshness==="expired")return;

  const locationLayerId=unitLocationLayerId(unit);
  if(locationLayerId!==layer.id)return;

  let pixel;
  try{
    pixel=geoToPixel(Number(location.latitude),Number(location.longitude),layer.georef_coefficients);
  }catch{
    return;
  }

  // Do not pin a device far outside the actual venue image.
  if(pixel.x < -50 || pixel.y < -50 || pixel.x > Number(layer.image_width)+50 || pixel.y > Number(layer.image_height)+50){
    return;
  }

  const marker=L.circleMarker(
    pixelToLeaflet(pixel.x,pixel.y,layer.image_height),
    {
      radius:9,
      weight:3,
      fillOpacity:freshness==="live"?.9:.45,
      opacity:freshness==="live"?1:.55,
      className:`unit-gps-marker unit-gps-${freshness}`
    }
  ).addTo(S.map);

  marker.bindTooltip(unitLocationTooltip(unit,location),{direction:"top",offset:[0,-8]});
  S.unitLocationMarkers.set(unitId,{marker});
}

function renderAllUnitLocationMarkers(){
  S.unitLocationMarkers.forEach((_,unitId)=>removeUnitLocationMarker(unitId));
  S.unitLocationMarkers.clear();
  for(const location of S.unitLocations){
    const unit=S.units.find(u=>u.id===location.unit_id);
    if(unit&&unitInDispatchScope(unit))renderUnitLocationMarker(location.unit_id);
  }
}

function updateDispatcherUnitLocation(payload){
  const row=payload?.new;
  const old=payload?.old;

  if(payload.eventType==="DELETE"){
    const unitId=old?.unit_id;
    if(!unitId)return;
    S.unitLocations=S.unitLocations.filter(l=>l.unit_id!==unitId);
    removeUnitLocationMarker(unitId);
    updateUnitLocationBoardRow(unitId);
    return;
  }

  if(!row?.unit_id || !S.units.some(u=>u.id===row.unit_id))return;
  const index=S.unitLocations.findIndex(l=>l.unit_id===row.unit_id);
  if(index>=0)S.unitLocations[index]=row;
  else S.unitLocations.push(row);
  const unit=S.units.find(u=>u.id===row.unit_id);
  if(unit&&unitInDispatchScope(unit))renderUnitLocationMarker(row.unit_id);
  else removeUnitLocationMarker(row.unit_id);
  updateUnitLocationBoardRow(row.unit_id);
}

function updateUnitLocationBoardRow(unitId){
  const location=unitLocation(unitId);
  const el=document.querySelector(`[data-unit-gps="${unitId}"]`);
  if(!el)return;
  if(!location){
    el.textContent=S.event?.field_location_enabled?"GPS not shared":"GPS disabled";
    el.className="small muted unit-gps-readout";
    return;
  }
  const freshness=locationFreshness(location);
  el.textContent=`${locationAgeLabel(location)}${location.accuracy_m!=null?` · ±${Math.round(location.accuracy_m)}m`:""}`;
  el.className=`small unit-gps-readout gps-${freshness}`;
}

function refreshLocationAges(){
  for(const unit of S.units){
    updateUnitLocationBoardRow(unit.id);
    const location=unitLocation(unit.id);
    if(location){
      const freshness=locationFreshness(location);
      if(freshness==="expired"||!unitInDispatchScope(unit))removeUnitLocationMarker(unit.id);
      else renderUnitLocationMarker(unit.id);
    }
  }
  if(document.querySelector("#commandDisplayShell"))renderCommandUnitMarkers();
}

function ensureLocationAgeTicker(){
  if(S.locationAgeInterval)return;
  S.locationAgeInterval=setInterval(refreshLocationAges,10000);
}

function activeAssignmentForUnit(unitId){
  for(const incident of S.incidents){
    const link=(incident.incident_units||[]).find(x=>x.unit_id===unitId && !x.cleared_at);
    if(link)return {incident,link};
  }
  return null;
}

function incidentList(){
  return S.incidents.filter(incidentInDispatchScope).map(i=>{
    const deps=(i.incident_departments||[]).map(d=>d.event_departments?.short_name||d.event_departments?.name).filter(Boolean).join("/");
    const assigned=(i.incident_units||[]).filter(x=>!x.cleared_at).map(x=>x.units?.name).filter(Boolean);
    return `<div class="incident" data-incident="${i.id}">
      <div class="row"><strong>${esc(i.incident_number)}</strong><span class="incident-head-meta"><span class="call-timer" title="Elapsed call time" data-call-start="${esc(i.created_at)}">00:00</span><span class="badge">${esc(i.priority)}</span></span></div>
      <div>${esc(i.call_type)}</div>
      <div class="small muted">${esc(deps)} · ${esc(layerName(i.map_layer_id))}${i.zone_id?` / ${esc(zoneName(i.zone_id))}`:""} · ${esc(i.landmark||"Mapped")}</div>
      ${assigned.length?`<div class="small" style="margin-top:5px"><strong>${esc(assigned.join(", "))}</strong></div>`:""}
    </div>`;
  }).join("")||`<div class="small muted">No active incidents.</div>`;
}

function unitList(){
  const groups={};
  for(const u of S.units.filter(unitInDispatchScope)){
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
        ${unitTransportDestinationLabel(u)?`<div class="small transport-destination-readout">Transport → ${esc(unitTransportDestinationLabel(u))}</div>`:""}
        <div class="small unit-gps-readout ${unitLocation(u.id)?`gps-${locationFreshness(unitLocation(u.id))}`:"muted"}" data-unit-gps="${u.id}">${unitLocation(u.id)?`${locationAgeLabel(unitLocation(u.id))}${unitLocation(u.id).accuracy_m!=null?` · ±${Math.round(unitLocation(u.id).accuracy_m)}m`:""}`:(S.event?.field_location_enabled?"GPS not shared":"GPS disabled")}</div>
      </button>`;
    }).join("")}
  `).join("")||`<div class="small muted">No units configured.</div>`;
}


function ensureIncidentModal(){
  let modal=document.querySelector("#incidentModal");
  if(modal)return modal;

  document.body.insertAdjacentHTML("beforeend",`
    <div class="incident-modal-backdrop" id="incidentModal" aria-hidden="true">
      <div class="incident-modal" role="dialog" aria-modal="true" aria-labelledby="incidentModalTitle">
        <div id="incidentModalContent"></div>
      </div>
    </div>
  `);

  modal=document.querySelector("#incidentModal");
  modal.addEventListener("mousedown",event=>{
    if(event.target===modal)closeIncidentModal();
  });
  return modal;
}

function openIncidentModalShell(){
  const modal=ensureIncidentModal();
  modal.classList.add("open");
  modal.setAttribute("aria-hidden","false");
  document.body.classList.add("modal-open");
  return document.querySelector("#incidentModalContent");
}

function closeIncidentModal(){
  const modal=document.querySelector("#incidentModal");
  if(modal){
    modal.classList.remove("open");
    modal.setAttribute("aria-hidden","true");
  }
  document.body.classList.remove("modal-open");
  S.openIncidentId=null;
  S.openUnitId=null;
  S.incidentModalMode=null;
}

document.addEventListener("keydown",event=>{
  if(event.key==="Escape"&&document.querySelector("#incidentModal.open")){
    closeIncidentModal();
  }
});

function incidentDepartmentNames(i){
  return (i.incident_departments||[])
    .map(link=>link.event_departments?.name||S.departments.find(d=>d.id===link.department_id)?.name)
    .filter(Boolean);
}

function activityTitle(action){
  const labels={
    INCIDENT_CREATED:"Incident created",
    INCIDENT_UPDATED:"Call details updated",
    UNIT_ASSIGNED:"Unit assigned",
    UNIT_UNASSIGNED:"Unit unassigned",
    UNIT_STATUS_CHANGED:"Unit status changed",
    EMS_FLOW_STARTED:"EMS flow started",
    EMS_HANDOFF_REQUESTED:"EMS handoff requested",
    EMS_HANDOFF_ACCEPTED:"EMS handoff accepted",
    EMS_HANDOFF_DECLINED:"EMS handoff declined",
    EMS_HANDOFF_CANCELLED:"EMS handoff cancelled",
    EMS_TREATMENT_RECEIVED:"Treatment-area custody confirmed",
    EMS_CUSTODY_SET:"EMS custody recorded",
    UNIT_ARRIVED_TREATMENT_AREA:"Unit arrived at treatment area",
    EMS_TRANSPORT_STARTED:"Transport started",
    EMS_TRANSPORT_COMPLETED:"Patient delivered",
    EMS_TRANSPORT_REFUSAL:"Transport ended with refusal",
    INCIDENT_CLOSED:"Incident closed"
  };
  return labels[action]||String(action||"Activity").replaceAll("_"," ").toLowerCase().replace(/^\w/,c=>c.toUpperCase());
}

function activitySummary(row){
  const d=row.detail||{};
  if(row.action==="UNIT_ASSIGNED"){
    const u=S.units.find(x=>x.id===row.unit_id);
    return u?u.name:"Unit assigned";
  }
  if(row.action==="UNIT_UNASSIGNED"){
    const u=S.units.find(x=>x.id===row.unit_id);
    return u?`${u.name}${d.new_status?` → ${String(d.new_status).replaceAll("_"," ")}`:""}`:"Unit cleared";
  }
  if(row.action==="UNIT_STATUS_CHANGED"){
    const u=S.units.find(x=>x.id===row.unit_id);
    return `${u?.name||"Unit"}${d.old_status||d.new_status?` · ${String(d.old_status||"").replaceAll("_"," ")}${d.new_status?` → ${String(d.new_status).replaceAll("_"," ")}`:""}`:""}`;
  }
  if(row.action==="INCIDENT_UPDATED"){
    const changes=[];
    if(d.old_call_type!==undefined&&d.old_call_type!==d.new_call_type)changes.push(`${d.old_call_type||"Nature"} → ${d.new_call_type||""}`);
    if(d.old_priority!==undefined&&d.old_priority!==d.new_priority)changes.push(`${d.old_priority||"Priority"} → ${d.new_priority||""}`);
    if(d.old_landmark!==undefined&&d.old_landmark!==d.new_landmark)changes.push(`Location → ${d.new_landmark||"updated"}`);
    return changes.join(" · ")||"Call information changed";
  }
  if(row.action==="EMS_TREATMENT_RECEIVED"){
    return `${d.incident_number||""}${d.treatment_area_name?` → ${d.treatment_area_name}`:""}${d.confirmation_source?` · confirmed by ${d.confirmation_source}`:""}`;
  }
  if(row.action==="EMS_CUSTODY_SET"){
    const unit=d.to_unit_id?S.units.find(u=>u.id===d.to_unit_id)?.name:null;
    return `${d.incident_number||""}${unit?` → ${unit}`:""}`;
  }
  if(row.action==="UNIT_ARRIVED_TREATMENT_AREA"){
    return d.treatment_area_name?`Patient received at ${d.treatment_area_name}`:"Patient received at treatment area";
  }
  if(row.action==="EMS_TRANSPORT_COMPLETED"){
    return d.destination?`Delivered to ${d.destination}`:"Patient delivered to destination facility";
  }
  if(row.action==="EMS_TRANSPORT_REFUSAL"){
    return d.destination?`Patient refusal · transport had been en route to ${d.destination}`:"Patient refusal obtained";
  }
  if(d.incident_number)return d.incident_number;
  if(d.status)return String(d.status).replaceAll("_"," ");
  if(d.destination)return d.destination;
  return "";
}

function emsCustodyName(encounter,areas){
  if(!encounter)return "No EMS custody record";
  if(encounter.current_treatment_area_id){
    return areas.find(a=>a.id===encounter.current_treatment_area_id)?.name||"Treatment Area";
  }
  if(encounter.current_unit_id){
    return S.units.find(u=>u.id===encounter.current_unit_id)?.name||"Field / Transport Unit";
  }
  return String(encounter.current_status||"EMS Flow").replaceAll("_"," ");
}

function handoffResourceName({unitId,areaId},areas){
  if(unitId)return S.units.find(u=>u.id===unitId)?.name||"Unit";
  if(areaId)return areas.find(a=>a.id===areaId)?.name||"Treatment Area";
  return "Unknown";
}

async function loadIncidentCommandData(incidentId){
  const [activityRes,encounterRes,areasRes]=await Promise.all([
    supabase.from("cad_activity")
      .select("id,action,detail,unit_id,actor_kind,created_at")
      .eq("event_id",S.eventId)
      .eq("incident_id",incidentId)
      .order("created_at",{ascending:false})
      .limit(60),
    supabase.from("ems_encounters")
      .select("*")
      .eq("event_id",S.eventId)
      .eq("incident_id",incidentId)
      .neq("current_status","CLOSED")
      .order("created_at")
      .limit(1)
      .maybeSingle(),
    supabase.from("ems_treatment_areas")
      .select("id,name,status,accepting_patients")
      .eq("event_id",S.eventId)
      .eq("active",true)
      .order("name")
  ]);

  if(activityRes.error)console.warn("Incident activity could not be loaded",activityRes.error);
  if(encounterRes.error)console.warn("Incident EMS custody could not be loaded",encounterRes.error);
  if(areasRes.error)console.warn("Treatment areas could not be loaded",areasRes.error);

  const encounter=encounterRes.data||null;
  let handoffs=[];
  if(encounter){
    const {data,error}=await supabase.from("ems_handoffs")
      .select("*")
      .eq("encounter_id",encounter.id)
      .order("requested_at",{ascending:false});
    if(error)console.warn("Incident EMS handoffs could not be loaded",error);
    else handoffs=data||[];
  }

  return {
    activity:activityRes.data||[],
    encounter,
    handoffs,
    areas:areasRes.data||[]
  };
}

function incidentLocationHtml(i){
  const parts=[
    i.landmark||"",
    layerName(i.map_layer_id),
    i.zone_id?zoneName(i.zone_id):""
  ].filter(Boolean);

  return `<div class="incident-location-block">
    <div class="big">${esc(parts[0]||"No location description")}</div>
    ${parts.slice(1).length?`<div class="small muted">${esc(parts.slice(1).join(" · "))}</div>`:""}
    ${i.latitude!=null&&i.longitude!=null?`<div class="small mono muted">${Number(i.latitude).toFixed(6)}, ${Number(i.longitude).toFixed(6)}</div>`:""}
  </div>`;
}

function incidentTimelineHtml(rows){
  return rows.map(row=>`
    <div class="incident-timeline-row">
      <div class="incident-timeline-time">${fmt(row.created_at)}</div>
      <div class="incident-timeline-dot"></div>
      <div>
        <strong>${esc(activityTitle(row.action))}</strong>
        ${activitySummary(row)?`<div class="small muted">${esc(activitySummary(row))}</div>`:""}
        <div class="small muted">${esc(row.actor_kind||"system")}</div>
      </div>
    </div>
  `).join("")||`<div class="small muted">No CAD activity has been recorded yet.</div>`;
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


function unitEmsConfig(unitId){
  return S.emsUnitConfigs.find(c=>c.unit_id===unitId&&c.active)||null;
}

function isAmbulanceUnit(unit){
  const config=unitEmsConfig(unit?.id);
  return !!(config&&(config.ems_role==="ambulance"||config.transport_capable));
}

function treatmentAreaName(id){
  return S.treatmentAreas.find(a=>a.id===id)?.name||"";
}

function unitTransportDestinationLabel(unit){
  if(!unit||unit.status!=="TRANSPORTING")return "";
  if(unit.current_transport_destination_text)return unit.current_transport_destination_text;
  if(unit.current_transport_treatment_area_id)return treatmentAreaName(unit.current_transport_treatment_area_id);
  return "";
}

function transportDestinationEditorHtml(unit){
  const ambulance=isAmbulanceUnit(unit);
  const visible=unit.status==="TRANSPORTING"?"":"hidden";
  return `<div class="transport-destination-editor ${visible}" id="unitTransportDestinationPanel">
    <div class="section-title">Transport Destination</div>
    ${ambulance?`
      <label>Destination facility</label>
      <input id="unitTransportFacility" value="${esc(unit.current_transport_destination_text||"")}" placeholder="Destination facility">
    `:`
      <label>Treatment area destination</label>
      <select id="unitTransportTreatmentArea">
        <option value="">Choose treatment area</option>
        ${S.treatmentAreas.filter(a=>a.status!=="CLOSED").map(a=>`
          <option value="${a.id}" ${unit.current_transport_treatment_area_id===a.id?"selected":""}>
            ${esc(a.name)} · ${esc(a.status)}
          </option>
        `).join("")}
      </select>
    `}
    <div class="grid2">
      <button class="btn" id="confirmUnitTransport">${unit.status==="TRANSPORTING"?"Update Destination":"Set Transporting"}</button>
      <button class="btn secondary" id="cancelUnitTransport">Cancel</button>
    </div>
  </div>`;
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

  document.querySelectorAll(`[data-dispatch-status-option="${unitId}"]`).forEach(btn=>{
    const active=btn.dataset.status===status;
    btn.classList.toggle("field-status-active",active);
    btn.setAttribute("aria-pressed",active?"true":"false");
  });

  const currentLabel=document.querySelector(`[data-unit-current-status="${unitId}"]`);
  if(currentLabel)currentLabel.textContent=String(status||"").replaceAll("_"," ");
}


async function getActiveAmbulanceTransport(unitId,incidentId=null){
  let q=supabase.from("ems_encounters")
    .select("id,incident_id,current_status,transport_destination,created_at")
    .eq("event_id",S.eventId)
    .eq("current_unit_id",unitId)
    .eq("current_status","TRANSPORTING")
    .order("created_at",{ascending:false})
    .limit(1);

  if(incidentId)q=q.eq("incident_id",incidentId);

  const {data,error}=await q.maybeSingle();
  if(error)throw error;
  return data||null;
}

function showAmbulanceTransportOutcomeModal({
  unitId,
  incidentId,
  unitName,
  incidentNumber,
  encounter,
  onComplete,
  onCancel
}){
  const destination=encounter?.transport_destination
    ||S.units.find(u=>u.id===unitId)?.current_transport_destination_text
    ||"Destination facility";

  S.incidentModalMode="transport-outcome";
  const content=openIncidentModalShell();

  content.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">AMBULANCE TRANSPORT</div>
      <div class="incident-modal-title-row"><h2 id="incidentModalTitle">Complete Transport</h2></div>
      <div class="incident-modal-nature">${esc(unitName||"Ambulance")}${incidentNumber?` · ${esc(incidentNumber)}`:""}</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Cancel transport outcome">×</button>
  </div>

  <div class="transport-outcome-modal stack">
    <div class="notice">
      <strong>Destination facility</strong><br>
      ${esc(destination)}
    </div>

    <p>Before this ambulance returns to <strong>AVAILABLE</strong>, confirm how the patient transport ended.</p>

    <div class="transport-outcome-options">
      <button class="transport-outcome-card delivered" id="transportDelivered">
        <strong>Patient Delivered</strong>
        <span>Patient was delivered to the destination facility. This will close the call.</span>
      </button>

      <button class="transport-outcome-card refusal" id="transportRefusal">
        <strong>Patient Refusal</strong>
        <span>The transport unit obtained a patient refusal. This will close the call.</span>
      </button>
    </div>

    <div class="small muted">
      Either selection closes the EMS patient flow and the CAD incident, clears all committed units from the call, and returns those units to AVAILABLE.
    </div>
  </div>

  <div class="incident-modal-footer">
    <button class="btn secondary" id="cancelTransportOutcome">Cancel</button>
  </div>`;

  const cancel=()=>{
    closeIncidentModal();
    if(onCancel)onCancel();
  };

  document.querySelector("#closeIncidentModal").onclick=cancel;
  document.querySelector("#cancelTransportOutcome").onclick=cancel;

  const finish=async(outcome)=>{
    const delivered=document.querySelector("#transportDelivered");
    const refusal=document.querySelector("#transportRefusal");
    delivered.disabled=true;
    refusal.disabled=true;

    const {error}=await supabase.rpc("ems_finish_ambulance_transport",{
      p_unit_id:unitId,
      p_incident_id:incidentId,
      p_outcome:outcome
    });

    if(error){
      delivered.disabled=false;
      refusal.disabled=false;
      return alert(error.message);
    }

    closeIncidentModal();
    if(onComplete)await onComplete(outcome);
  };

  document.querySelector("#transportDelivered").onclick=()=>finish("DELIVERED");
  document.querySelector("#transportRefusal").onclick=()=>finish("REFUSAL");
}

async function maybePromptAmbulanceTransportOutcome({
  unitId,
  incidentId,
  unitName,
  incidentNumber,
  onComplete,
  onCancel
}){
  try{
    const encounter=await getActiveAmbulanceTransport(unitId,incidentId);
    if(!encounter)return false;

    showAmbulanceTransportOutcomeModal({
      unitId,
      incidentId:encounter.incident_id,
      unitName,
      incidentNumber,
      encounter,
      onComplete,
      onCancel
    });
    return true;
  }catch(error){
    alert(error.message);
    return true;
  }
}

async function dispatcherSetUnitStatus(unitId,status,incidentId=null,{destinationText=null,treatmentAreaId=null}={}){
  const {error}=await supabase.rpc("staff_set_unit_status_v2",{
    p_unit_id:unitId,
    p_status:status,
    p_incident_id:incidentId,
    p_transport_destination_text:destinationText,
    p_transport_treatment_area_id:treatmentAreaId
  });
  if(error){
    alert(error.message);
    return false;
  }

  const unit=S.units.find(u=>u.id===unitId);
  if(unit){
    unit.status=status;
    unit.current_transport_destination_text=status==="TRANSPORTING"?destinationText:null;
    unit.current_transport_treatment_area_id=status==="TRANSPORTING"?treatmentAreaId:null;
  }
  updateDispatcherUnitStatusUI(unitId,status);
  refreshDispatchBoards();
  return true;
}

async function dispatcherUnassign(incidentId,unitId){
  if(!confirm("Remove this unit from the incident?"))return;
  const {error}=await supabase.rpc("unassign_unit",{
    p_incident_id:incidentId,
    p_unit_id:unitId,
    p_new_status:"AVAILABLE"
  });
  if(error)return alert(error.message);
  await loadEventOps();
  refreshDispatchBoards();
  if(S.openUnitId===unitId)selectUnit(unitId);
  else if(S.openIncidentId===incidentId&&S.incidentModalMode!=="edit")selectIncident(incidentId);
}

async function dispatcherAssign(incidentId,unitId){
  if(!incidentId||!unitId)return;
  const {error}=await supabase.rpc("assign_unit",{
    p_incident_id:incidentId,
    p_unit_id:unitId
  });
  if(error)return alert(error.message);
  await loadEventOps();
  refreshDispatchBoards();
  if(S.openUnitId===unitId)selectUnit(unitId);
  else if(S.openIncidentId===incidentId&&S.incidentModalMode!=="edit")selectIncident(incidentId);
}


async function selectIncident(id){
  const i=S.incidents.find(x=>x.id===id);
  if(!i)return;

  S.openIncidentId=id;
  S.openUnitId=null;
  S.incidentModalMode="overview";

  const content=openIncidentModalShell();
  content.innerHTML=`<div class="incident-modal-loading">Loading ${esc(i.incident_number)}…</div>`;

  const extra=await loadIncidentCommandData(id);

  // Incident may have been closed while detail was loading.
  const current=S.incidents.find(x=>x.id===id);
  if(!current){
    closeIncidentModal();
    return;
  }

  const assignedLinks=(current.incident_units||[]).filter(x=>!x.cleared_at);
  const assignedIds=new Set(assignedLinks.map(x=>x.unit_id));
  const latestTransfer=extra.handoffs.find(h=>h.status==="COMPLETED")||null;
  const deps=incidentDepartmentNames(current);

  content.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">ACTIVE INCIDENT</div>
      <div class="incident-modal-title-row">
        <h2 id="incidentModalTitle">${esc(current.incident_number)}</h2>
        <span class="badge">${esc(current.priority)}</span>
        <span class="call-timer modal-call-timer" title="Elapsed call time" data-call-start="${esc(current.created_at)}">00:00</span>
      </div>
      <div class="incident-modal-nature">${esc(current.call_type)}</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close incident details">×</button>
  </div>

  <div class="incident-modal-actions">
    <button class="btn" id="editIncident">Edit Call Details</button>
    <button class="btn secondary" id="emsTreatmentHandoff">EMS Handoff / Custody</button>
    <button class="btn secondary" id="showIncidentMap">Show on Map</button>
    <button class="btn danger" id="closeIncident">Close Incident</button>
  </div>

  <div class="incident-command-grid">
    <div class="incident-command-main stack">
      <section class="incident-info-section">
        <div class="section-title">Call Information</div>
        <div class="incident-summary-grid">
          <div><span class="small muted">Received</span><strong>${new Date(current.created_at).toLocaleString()}</strong></div>
          <div><span class="small muted">Elapsed</span><strong class="call-timer-text" data-call-start="${esc(current.created_at)}">00:00</strong></div>
          <div><span class="small muted">Departments</span><strong>${esc(deps.join(", ")||"None")}</strong></div>
          <div><span class="small muted">Status</span><strong>${esc(current.status||"OPEN")}</strong></div>
        </div>
      </section>

      <section class="incident-info-section">
        <div class="section-title">Location</div>
        ${incidentLocationHtml(current)}
      </section>

      <section class="incident-info-section">
        <div class="section-title">Dispatch Notes</div>
        <div class="incident-notes">${current.notes?esc(current.notes):`<span class="muted">No dispatch notes.</span>`}</div>
      </section>

      <section class="incident-info-section">
        <div class="row"><div class="section-title">Assigned Units</div><span class="badge">${assignedLinks.length}</span></div>
        <div class="incident-assigned-units">
          ${assignedLinks.map(link=>{
            const u=S.units.find(x=>x.id===link.unit_id);
            if(!u)return "";
            return `<div class="assignment-unit-row">
              <div>
                <strong>${esc(u.event_departments?.short_name||"")} · ${esc(u.name)}</strong><br>
                <span class="badge status-${esc(u.status)}" data-dispatch-unit-status="${u.id}">${esc(String(u.status||"").replaceAll("_"," "))}</span>
                <span class="small ${unitLocation(u.id)?`gps-${locationFreshness(unitLocation(u.id))}`:"muted"}" data-unit-gps="${u.id}">${unitLocation(u.id)?`${locationAgeLabel(unitLocation(u.id))}${unitLocation(u.id).accuracy_m!=null?` · ±${Math.round(unitLocation(u.id).accuracy_m)}m`:""}`:(S.event?.field_location_enabled?"GPS not shared":"GPS disabled")}</span>
              </div>
              <div class="assignment-unit-actions">
                ${unitTransportDestinationLabel(u)?`<span class="small transport-destination-readout">→ ${esc(unitTransportDestinationLabel(u))}</span>`:""}
                <button class="btn secondary" data-open-unit-controls="${u.id}">Unit Controls</button>
                <button class="btn danger" data-unassign-unit="${u.id}">Unassign</button>
              </div>
            </div>`;
          }).join("")||`<div class="small muted">No units assigned.</div>`}
        </div>

        <div class="incident-assign-row">
          <select id="assignUnit">
            <option value="">Assign another unit…</option>
            ${S.units.filter(u=>!assignedIds.has(u.id)).map(u=>{
              const active=activeAssignmentForUnit(u.id);
              return `<option value="${u.id}" ${active?"disabled":""}>${esc(u.event_departments?.short_name||"")} · ${esc(u.name)} · ${esc(u.status)}${active?` · ${esc(active.incident.incident_number)}`:""}</option>`;
            }).join("")}
          </select>
          <button class="btn" id="dispatchUnit">Assign Unit</button>
        </div>
      </section>

      <section class="incident-info-section">
        <div class="row"><div class="section-title">EMS / Patient Flow</div>${extra.encounter?`<span class="badge">${esc(String(extra.encounter.current_status||"").replaceAll("_"," "))}</span>`:""}</div>
        ${extra.encounter?`
          <div class="incident-ems-summary">
            <div><span class="small muted">Current custody</span><strong>${esc(emsCustodyName(extra.encounter,extra.areas))}</strong></div>
            ${latestTransfer?`<div><span class="small muted">Most recent handoff</span><strong>${esc(handoffResourceName({unitId:latestTransfer.from_unit_id,areaId:latestTransfer.from_treatment_area_id},extra.areas))} → ${esc(handoffResourceName({unitId:latestTransfer.to_unit_id,areaId:latestTransfer.to_treatment_area_id},extra.areas))}</strong></div>`:""}
            ${extra.encounter.transport_destination?`<div><span class="small muted">Destination</span><strong>${esc(extra.encounter.transport_destination)}</strong></div>`:""}
          </div>
        `:`<div class="small muted">No EMS custody has been recorded for this incident.</div>`}
      </section>
    </div>

    <aside class="incident-command-side">
      <section class="incident-info-section">
        <div class="row"><div class="section-title">CAD Activity</div><span class="badge">${extra.activity.length}</span></div>
        <div class="incident-timeline">${incidentTimelineHtml(extra.activity)}</div>
      </section>
    </aside>
  </div>`;

  ensureCallTimerTicker();

  document.querySelector("#closeIncidentModal").onclick=()=>closeIncidentModal();
  document.querySelector("#editIncident").onclick=()=>editIncidentForm(current.id);

  document.querySelector("#emsTreatmentHandoff").onclick=()=>{
    S.incidentModalMode="ems";
    renderDispatchIncidentTreatmentPanel(
      document.querySelector("#incidentModalContent"),
      {eventId:S.eventId,incidentId:current.id,onBack:()=>selectIncident(current.id)}
    );
  };

  document.querySelector("#showIncidentMap").onclick=async()=>{
    if(current.map_layer_id&&current.map_layer_id!==S.activeMapLayerId){
      S.activeMapLayerId=current.map_layer_id;
      saveNavigationState();
      const select=document.querySelector("#dispatchLayerSelect");
      if(select)select.value=current.map_layer_id;
      await setupDispatchMap();
    }
    const layer=activeMapLayer();
    if(S.map&&layer&&current.map_x!=null&&current.map_y!=null){
      S.map.setView(pixelToLeaflet(current.map_x,current.map_y,layer.image_height),Math.max(S.map.getZoom(),1));
    }
    closeIncidentModal();
  };

  document.querySelector("#dispatchUnit").onclick=async()=>{
    const unitId=document.querySelector("#assignUnit").value;
    if(!unitId)return;
    const {error}=await supabase.rpc("assign_unit",{p_incident_id:current.id,p_unit_id:unitId});
    if(error)return alert(error.message);
    await loadEventOps();
    refreshDispatchBoards();
    selectIncident(current.id);
  };

  document.querySelectorAll("[data-open-unit-controls]").forEach(b=>b.onclick=()=>selectUnit(b.dataset.openUnitControls));

  document.querySelectorAll("[data-unassign-unit]").forEach(b=>b.onclick=async()=>{
    if(!confirm("Remove this unit from the incident?"))return;
    const {error}=await supabase.rpc("unassign_unit",{
      p_incident_id:current.id,
      p_unit_id:b.dataset.unassignUnit,
      p_new_status:"AVAILABLE"
    });
    if(error)return alert(error.message);
    await loadEventOps();
    refreshDispatchBoards();
    selectIncident(current.id);
  });

  document.querySelector("#closeIncident").onclick=async()=>{
    const disposition=prompt("Disposition:","Complete");
    if(disposition===null)return;
    const {error}=await supabase.rpc("close_incident",{p_incident_id:current.id,p_disposition:disposition});
    if(error)return alert(error.message);
    closeIncidentModal();
    await loadEventOps();
    refreshDispatchBoards();
  };

  if(current.map_layer_id&&current.map_layer_id!==S.activeMapLayerId){
    S.activeMapLayerId=current.map_layer_id;
    saveNavigationState();
  }
}

function refreshDispatchBoards(){
  const incidentHost=document.querySelector("#incidentList");
  const unitHost=document.querySelector("#unitList");
  if(incidentHost)incidentHost.innerHTML=incidentList();
  if(unitHost)unitHost.innerHTML=unitList();
  updateDispatchScopeUi();
  bindIncidentClicks();
  refreshLocationAges();
}


async function focusUnitOnDispatchMap(unitId){
  const unit=S.units.find(u=>u.id===unitId);
  const location=unitLocation(unitId);
  if(!unit||!location)return alert("This unit is not currently sharing a GPS location.");

  const layerId=unitLocationLayerId(unit);
  if(layerId&&layerId!==S.activeMapLayerId){
    S.activeMapLayerId=layerId;
    saveNavigationState();
    const selector=document.querySelector("#dispatchLayerSelect");
    if(selector)selector.value=layerId;
    await setupDispatchMap();
  }

  const layer=activeMapLayer();
  if(!S.map||!layer?.georef_coefficients)return;

  let pixel;
  try{
    pixel=geoToPixel(Number(location.latitude),Number(location.longitude),layer.georef_coefficients);
  }catch{
    return;
  }

  S.map.setView(pixelToLeaflet(pixel.x,pixel.y,layer.image_height),Math.max(S.map.getZoom(),1));
  const marker=S.unitLocationMarkers.get(unitId)?.marker;
  if(marker)marker.openTooltip();
}

function unitStatusButtonsHtml(u,active){
  return `<div class="status-buttons dispatcher-status-grid">
    ${unitStatusOptions(u).map(status=>`
      <button
        class="btn field-status-button ${fieldStatusColorClass(status)} ${status===u.status?"field-status-active":""}"
        data-dispatch-status-option="${u.id}"
        data-status="${esc(status)}"
        aria-pressed="${status===u.status?"true":"false"}"
      >${esc(status.replaceAll("_"," "))}</button>
    `).join("")}
  </div>
  <div class="small muted">${active?"Status changes are associated with the current incident.":"Choose a status for this unit."}</div>`;
}

function selectUnit(unitId){
  const u=S.units.find(x=>x.id===unitId);
  if(!u)return;

  const active=activeAssignmentForUnit(unitId);
  const location=unitLocation(unitId);
  const layerId=unitLocationLayerId(u);
  const layer=layerId?S.mapLayers.find(l=>l.id===layerId):null;
  const zone=u.current_zone_id?S.zones.find(z=>z.id===u.current_zone_id):null;

  S.openIncidentId=null;
  S.openUnitId=unitId;
  S.incidentModalMode="unit";

  const content=openIncidentModalShell();
  content.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">${esc(u.event_departments?.name||"UNIT")}</div>
      <div class="incident-modal-title-row">
        <h2 id="incidentModalTitle">${esc(u.name)}</h2>
        <span class="badge status-${esc(u.status)}" data-dispatch-unit-status="${u.id}" data-unit-current-status="${u.id}">${esc(u.status.replaceAll("_"," "))}</span>
      </div>
      <div class="incident-modal-nature">${active?`Committed to ${esc(active.incident.incident_number)}`:"Available for assignment"}${unitTransportDestinationLabel(u)?` · Transporting to ${esc(unitTransportDestinationLabel(u))}`:""}</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close unit controls">×</button>
  </div>

  <div class="unit-command-modal" data-unit-detail-id="${u.id}">
    <section class="unit-command-main stack">
      <div class="incident-info-section">
        <div class="section-title">Unit Status</div>
        ${unitStatusButtonsHtml(u,active)}
        ${transportDestinationEditorHtml(u)}
        ${active&&!isAmbulanceUnit(u)&&u.status==="TRANSPORTING"&&u.current_transport_treatment_area_id?`
          <div class="treatment-arrival-action">
            <div>
              <div class="section-title">Treatment Area Arrival</div>
              <strong>${esc(treatmentAreaName(u.current_transport_treatment_area_id)||"Treatment Area")}</strong>
              <div class="small muted">Marks the patient received at the treatment area, clears this unit from the incident, and returns the unit to AVAILABLE.</div>
            </div>
            <button class="btn good block" id="arriveUnitTreatmentArea">Arrived at Treatment Area</button>
          </div>
        `:""}
      </div>

      <div class="incident-info-section">
        <div class="row"><div class="section-title">CAD Assignment</div>${active?`<span class="badge">COMMITTED</span>`:`<span class="badge">UNASSIGNED</span>`}</div>
        ${active?`
          <div class="unit-current-assignment">
            <strong>${esc(active.incident.incident_number)} · ${esc(active.incident.call_type)}</strong>
            <div class="small muted">${esc(active.incident.landmark||"")}</div>
          </div>
          <div class="grid2">
            <button class="btn" id="openAssignedIncident">Open Incident</button>
            <button class="btn danger" id="removeAssignment">Clear Unit from Incident</button>
          </div>
        `:`
          <div>
            <label>Assign to incident</label>
            <select id="unitIncident">
              <option value="">Choose active incident</option>
              ${S.incidents.filter(incidentInDispatchScope).map(i=>`<option value="${i.id}">${esc(i.incident_number)} · ${esc(i.call_type)} · ${esc(i.landmark||"")}</option>`).join("")}
            </select>
          </div>
          <button class="btn" id="assignFromUnit">Commit Unit to Incident</button>
        `}
      </div>
    </section>

    <aside class="unit-command-side stack">
      <div class="incident-info-section">
        <div class="section-title">Live Location</div>
        ${location?`
          <div class="unit-location-large ${`gps-${locationFreshness(location)}`}">
            <strong data-unit-gps="${u.id}">${esc(locationAgeLabel(location))}${location.accuracy_m!=null?` · ±${Math.round(location.accuracy_m)}m`:""}</strong>
            <div class="small muted">${layer?esc(layer.name):"Map layer not set"}${zone?` · ${esc(zone.name)}`:""}</div>
            <div class="small mono muted">${Number(location.latitude).toFixed(6)}, ${Number(location.longitude).toFixed(6)}</div>
          </div>
          <button class="btn secondary block" id="showUnitOnMap">Show Unit on Map</button>
        `:`<div class="small muted">${S.event?.field_location_enabled?"This unit is not currently sharing GPS.":"Field GPS sharing is disabled for this event."}</div>`}
      </div>

      <div class="incident-info-section">
        <div class="section-title">Venue Post</div>
        <label>Map layer</label>
        <select id="unitLayer">
          <option value="">No level/post</option>
          ${S.mapLayers.filter(l=>l.status==="published").map(l=>`<option value="${l.id}" ${u.current_map_layer_id===l.id?"selected":""}>${esc(l.name)}</option>`).join("")}
        </select>
        <label>Zone</label>
        <select id="unitZone">
          <option value="">No zone</option>
          ${S.zones.filter(z=>!u.current_map_layer_id||z.map_layer_id===u.current_map_layer_id).map(z=>`<option value="${z.id}" ${u.current_zone_id===z.id?"selected":""}>${esc(z.name)}</option>`).join("")}
        </select>
        <button class="btn secondary block" id="saveUnitLocation">Update Post</button>
      </div>
    </aside>
  </div>`;

  document.querySelector("#closeIncidentModal").onclick=()=>closeIncidentModal();

  document.querySelectorAll(`[data-dispatch-status-option="${u.id}"]`).forEach(btn=>btn.onclick=async()=>{
    const status=btn.dataset.status;

    if(status==="TRANSPORTING"){
      document.querySelector("#unitTransportDestinationPanel")?.classList.remove("hidden");
      document.querySelector(isAmbulanceUnit(u)?"#unitTransportFacility":"#unitTransportTreatmentArea")?.focus();
      return;
    }

    if(
      status==="AVAILABLE"
      &&isAmbulanceUnit(u)
      &&active?.incident?.id
    ){
      const handled=await maybePromptAmbulanceTransportOutcome({
        unitId,
        incidentId:active.incident.id,
        unitName:u.name,
        incidentNumber:active.incident.incident_number,
        onComplete:async()=>{
          await loadEventOps();
          refreshDispatchBoards();
          selectUnit(unitId);
        },
        onCancel:()=>selectUnit(unitId)
      });
      if(handled)return;
    }

    if(status===u.status)return;

    document.querySelectorAll(`[data-dispatch-status-option="${u.id}"]`).forEach(b=>b.disabled=true);
    const ok=await dispatcherSetUnitStatus(unitId,status,active?.incident.id||null);
    document.querySelectorAll(`[data-dispatch-status-option="${u.id}"]`).forEach(b=>b.disabled=false);
    if(ok)selectUnit(unitId);
  });

  document.querySelector("#cancelUnitTransport")?.addEventListener("click",()=>{
    if(u.status!=="TRANSPORTING")document.querySelector("#unitTransportDestinationPanel")?.classList.add("hidden");
  });

  document.querySelector("#confirmUnitTransport")?.addEventListener("click",async()=>{
    const ambulance=isAmbulanceUnit(u);
    const destinationText=ambulance?document.querySelector("#unitTransportFacility").value.trim():null;
    const treatmentAreaId=ambulance?null:(document.querySelector("#unitTransportTreatmentArea").value||null);

    if(ambulance&&!destinationText)return alert("Enter the destination facility.");
    if(!ambulance&&!treatmentAreaId)return alert("Choose the treatment area destination.");

    const button=document.querySelector("#confirmUnitTransport");
    button.disabled=true;
    const ok=await dispatcherSetUnitStatus(
      unitId,
      "TRANSPORTING",
      active?.incident.id||null,
      {destinationText,treatmentAreaId}
    );
    button.disabled=false;
    if(ok)selectUnit(unitId);
  });

  document.querySelector("#arriveUnitTreatmentArea")?.addEventListener("click",async()=>{
    if(!active)return;
    const areaName=treatmentAreaName(u.current_transport_treatment_area_id)||"the treatment area";
    if(!confirm(`Confirm ${u.name} has arrived at ${areaName} with the patient?`))return;

    const button=document.querySelector("#arriveUnitTreatmentArea");
    button.disabled=true;
    button.textContent="Recording Arrival…";

    const {data,error}=await supabase.rpc("unit_arrive_treatment_area",{
      p_unit_id:unitId,
      p_incident_id:active.incident.id
    });

    if(error){
      button.disabled=false;
      button.textContent="Arrived at Treatment Area";
      return alert(error.message);
    }

    await loadEventOps();
    refreshDispatchBoards();
    alert(`${u.name} arrived at ${data||areaName}. Patient custody is now with the treatment area and the unit is AVAILABLE.`);
    selectUnit(unitId);
  });

  document.querySelector("#unitLayer").onchange=e=>{
    const selectedLayer=e.target.value;
    document.querySelector("#unitZone").innerHTML=`<option value="">No zone</option>${S.zones.filter(z=>z.map_layer_id===selectedLayer).map(z=>`<option value="${z.id}">${esc(z.name)}</option>`).join("")}`;
  };

  document.querySelector("#saveUnitLocation").onclick=async()=>{
    const button=document.querySelector("#saveUnitLocation");
    button.disabled=true;
    button.textContent="Saving…";
    const {error}=await supabase.rpc("staff_set_unit_location",{
      p_unit_id:unitId,
      p_map_layer_id:document.querySelector("#unitLayer").value||null,
      p_zone_id:document.querySelector("#unitZone").value||null,
      p_poi_id:null
    });
    if(error){
      button.disabled=false;
      button.textContent="Update Post";
      return alert(error.message);
    }
    await loadEventOps();
    refreshDispatchBoards();
    selectUnit(unitId);
  };

  document.querySelector("#showUnitOnMap")?.addEventListener("click",async()=>{
    await focusUnitOnDispatchMap(unitId);
    closeIncidentModal();
  });

  if(active){
    document.querySelector("#openAssignedIncident").onclick=()=>selectIncident(active.incident.id);
    document.querySelector("#removeAssignment").onclick=()=>dispatcherUnassign(active.incident.id,unitId);
  }else{
    document.querySelector("#assignFromUnit").onclick=()=>{
      const incidentId=document.querySelector("#unitIncident").value;
      if(!incidentId)return alert("Choose an active incident.");
      dispatcherAssign(incidentId,unitId);
    };
  }
}

async function setupDispatchMap(){
  S.unitLocationMarkers.clear();
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
    L.marker(pixelToLeaflet(p.map_x,p.map_y,layer.image_height),{icon:poiMapIcon()}).addTo(S.map).bindTooltip(p.name,{direction:"top",offset:[0,-4]});
  }
  for(const n of S.accessNodes.filter(n=>n.map_layer_id===layer.id)){
    const ap=S.accessPoints.find(a=>a.id===n.access_point_id);
    L.circleMarker(pixelToLeaflet(n.map_x,n.map_y,layer.image_height),{radius:6,className:"access-marker"}).addTo(S.map).bindTooltip(`${ap?.name||"Access"} · ${ap?.access_type||""}`);
  }
  for(const i of S.incidents.filter(i=>incidentInDispatchScope(i)&&(!i.map_layer_id||i.map_layer_id===layer.id))){
    if(i.map_x!=null&&i.map_y!=null)L.circleMarker(pixelToLeaflet(i.map_x,i.map_y,layer.image_height),{radius:8,className:"incident-marker"}).addTo(S.map).bindTooltip(i.incident_number);
  }
  renderAllUnitLocationMarkers();
  if(layer.georef_coefficients){
    S.map.on("click",async e=>{
      const px=leafletToPixel(e.latlng,layer.image_height);
      const geo=pixelToGeo(px.x,px.y,layer.georef_coefficients);
      S.currentLocation={map_x:px.x,map_y:px.y,latitude:geo.lat,longitude:geo.lon,poi_id:null,landmark:"",map_layer_id:layer.id,zone_id:null};

      if(S.mapPickMode==="incident"){
        const draft=S.pendingIncidentDraft;
        S.mapPickMode=null;S.pendingIncidentDraft=null;hideMapPickBanner();
        incidentForm(S.currentLocation,draft);
        return;
      }
      if(S.mapPickMode==="poi"){
        S.mapPickMode=null;hideMapPickBanner();
        dispatcherPoiForm(S.currentLocation);
        return;
      }

      L.popup().setLatLng(e.latlng).setContent(
        `<strong>${esc(layer.name)}</strong><br>${geo.lat.toFixed(6)}, ${geo.lon.toFixed(6)}
        <div class="map-popup-actions"><button id="createAtPoint">Create Incident Here</button><button id="addPoiAtPoint">Add POI Here</button></div>`
      ).openOn(S.map);
      setTimeout(()=>{
        document.querySelector("#createAtPoint")?.addEventListener("click",()=>incidentForm(S.currentLocation));
        document.querySelector("#addPoiAtPoint")?.addEventListener("click",()=>dispatcherPoiForm(S.currentLocation));
      },0);
    });
  }
}



function incidentForm(loc,draft=null){
  S.openIncidentId=null;
  S.openUnitId=null;
  S.incidentModalMode="new";

  const detail=openIncidentModalShell();
  const defaultDepartmentIds=normalizeDepartmentSelection(
    draft?.departmentIds?.length?draft.departmentIds:S.dispatchDepartmentIds
  );

  detail.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">NEW INCIDENT</div>
      <div class="incident-modal-title-row"><h2 id="incidentModalTitle">Create Call</h2></div>
      <div class="incident-modal-nature">Dispatching for ${esc(scopeLabel())}</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close new incident form">×</button>
  </div>

  <div class="new-incident-modal-body" data-incident-modal-mode="new">
    <section class="new-incident-primary stack">
      <div class="grid2">
        <div><label>Call Type / Nature</label><input id="callType" autofocus placeholder="Call type / nature" value="${esc(draft?.callType||"")}"></div>
        <div><label>Priority</label><select id="priority">
          ${["Standard","Urgent","Critical"].map(p=>`<option ${draft?.priority===p?"selected":(!draft&&p==="Standard"?"selected":"")}>${p}</option>`).join("")}
        </select></div>
      </div>

      <div>
        <div class="row">
          <label>Location / POI</label>
          <button class="btn secondary compact" id="pickIncidentMapLocation">Pick on Map</button>
        </div>
        <input id="poiSearchNew" autocomplete="off" placeholder="Search POIs">
        <div id="poiSearchNewResults" class="poi-search-results"></div>
      </div>

      <div><label>Location Description</label><input id="landmark" value="${esc(loc?.landmark||draft?.landmark||"")}"></div>

      <div class="notice">
        <strong>Selected location</strong><br>
        <span id="locSummary">${loc?`${loc.map_layer_id?`${esc(layerName(loc.map_layer_id))} · `:""}${Number(loc.latitude).toFixed(6)}, ${Number(loc.longitude).toFixed(6)}`:"Search for a POI or choose Pick on Map."}</span>
      </div>

      <div><label>Dispatch Notes</label><textarea id="notes" rows="7" placeholder="Operational notes">${esc(draft?.notes||"")}</textarea></div>
    </section>

    <aside class="new-incident-side stack">
      <div>
        <div class="section-title">Departments for this call</div>
        <div class="small muted" style="margin-bottom:8px">Your dispatch scope is preselected automatically. Change this only when this call involves a different combination of departments.</div>
        <div class="new-call-department-list">
          ${S.departments.map(d=>`<label class="status-select-option">
            <input type="checkbox" name="dept" value="${d.id}" ${defaultDepartmentIds.includes(d.id)?"checked":""}>
            <span>${esc(d.name)}</span>
          </label>`).join("")}
        </div>
      </div>

      <div>
        <div class="section-title">Initial Unit Assignment</div>
        <div class="small muted" style="margin-bottom:7px">Available choices follow the departments selected for this call.</div>
        <div class="create-unit-grid" id="newIncidentUnitChoices"></div>
      </div>
    </aside>
  </div>

  <div class="incident-modal-footer">
    <button class="btn secondary" id="cancelNewIncident">Cancel</button>
    <button class="btn secondary" id="saveIncidentOnly">Create Without Assignment</button>
    <button class="btn" id="saveAndDispatch">Create & Dispatch Selected</button>
  </div>`;

  let chosen=loc?{...loc}:null;
  let preservedUnitIds=new Set(draft?.initialUnitIds||[]);

  const renderUnitChoices=()=>{
    const selectedDeps=new Set([...document.querySelectorAll('input[name="dept"]:checked')].map(x=>x.value));
    document.querySelectorAll('input[name="initialUnit"]:checked').forEach(x=>preservedUnitIds.add(x.value));

    const units=S.units.filter(u=>selectedDeps.has(u.department_id));
    const host=document.querySelector("#newIncidentUnitChoices");
    host.innerHTML=units.map(u=>{
      const active=activeAssignmentForUnit(u.id);
      return `<label class="create-unit-option ${active?"disabled":""}">
        <input type="checkbox" name="initialUnit" value="${u.id}" ${active?"disabled":""} ${!active&&preservedUnitIds.has(u.id)?"checked":""}>
        <span><strong>${esc(u.event_departments?.short_name||"")} · ${esc(u.name)}</strong><br>
        <span class="small muted" data-create-unit-status="${u.id}">${esc(u.status.replaceAll("_"," "))}${active?` · ${esc(active.incident.incident_number)}`:""}</span></span>
      </label>`;
    }).join("")||`<div class="small muted">No units are configured for the selected department(s).</div>`;
  };

  renderUnitChoices();
  document.querySelectorAll('input[name="dept"]').forEach(el=>el.addEventListener("change",renderUnitChoices));

  document.querySelector("#closeIncidentModal").onclick=()=>closeIncidentModal();
  document.querySelector("#cancelNewIncident").onclick=()=>closeIncidentModal();
  document.querySelector("#pickIncidentMapLocation").onclick=()=>startIncidentMapPlacement();

  bindPoiSearch({
    inputId:"poiSearchNew",
    resultsId:"poiSearchNewResults",
    onSelect:p=>{
      chosen=poiLocationObject(p);
      document.querySelector("#landmark").value=p.name;
      document.querySelector("#locSummary").textContent=`${layerName(p.map_layer_id)||"Unlayered"}${p.zone_id?` / ${zoneName(p.zone_id)}`:""} · ${Number(p.latitude).toFixed(6)}, ${Number(p.longitude).toFixed(6)}`;
      focusPoiOnMap(p);
    }
  });

  const create=async(assignSelected)=>{
    if(!chosen)return alert("Choose a POI or use Pick on Map to set the incident location.");

    const deps=[...document.querySelectorAll('input[name="dept"]:checked')].map(x=>x.value);
    if(!deps.length)return alert("Choose at least one department.");

    const callType=document.querySelector("#callType").value.trim();
    if(!callType)return alert("Enter a call type / nature.");

    const selectedUnits=assignSelected
      ? [...document.querySelectorAll('input[name="initialUnit"]:checked')].map(x=>x.value)
      : [];

    const buttons=[document.querySelector("#saveIncidentOnly"),document.querySelector("#saveAndDispatch")];
    buttons.forEach(b=>{if(b)b.disabled=true;});

    const {data,error}=await supabase.rpc("create_incident_v3",{
      p_event_id:S.eventId,
      p_department_ids:deps,
      p_call_type:callType,
      p_priority:document.querySelector("#priority").value,
      p_latitude:chosen.latitude,
      p_longitude:chosen.longitude,
      p_map_x:chosen.map_x,
      p_map_y:chosen.map_y,
      p_landmark:document.querySelector("#landmark").value.trim(),
      p_notes:document.querySelector("#notes").value.trim(),
      p_poi_id:chosen.poi_id||null,
      p_map_layer_id:chosen.map_layer_id||S.activeMapLayerId||null,
      p_zone_id:chosen.zone_id||null
    });

    if(error){
      buttons.forEach(b=>{if(b)b.disabled=false;});
      console.error("CommCenter Pro create incident error",error);
      return alert(`Incident was NOT created.\n\n${error.message}${error.hint?`\n\nHint: ${error.hint}`:""}`);
    }

    const createdId=data;
    const failures=[];

    for(const unitId of selectedUnits){
      const result=await supabase.rpc("assign_unit",{p_incident_id:createdId,p_unit_id:unitId});
      if(result.error)failures.push(result.error.message);
    }

    closeIncidentModal();
    await loadEventOps();
    refreshDispatchBoards();
    await setupDispatchMap();
    if(createdId)selectIncident(createdId);

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

  S.openIncidentId=incidentId;
  S.openUnitId=null;
  S.incidentModalMode="edit";

  let chosen={
    poi_id:i.poi_id||null,
    map_x:i.map_x,
    map_y:i.map_y,
    latitude:i.latitude,
    longitude:i.longitude,
    landmark:i.landmark,
    map_layer_id:i.map_layer_id||null,
    zone_id:i.zone_id||null
  };

  const selectedDepartments=new Set((i.incident_departments||[]).map(d=>d.department_id));
  const detail=openIncidentModalShell();

  detail.innerHTML=`<div class="incident-modal-header">
    <div>
      <div class="incident-modal-eyebrow">EDIT ACTIVE INCIDENT</div>
      <div class="incident-modal-title-row">
        <h2 id="incidentModalTitle">${esc(i.incident_number)}</h2>
        <span class="call-timer modal-call-timer" data-call-start="${esc(i.created_at)}">00:00</span>
      </div>
      <div class="incident-modal-nature">${esc(i.call_type)}</div>
    </div>
    <button class="incident-modal-close" id="closeIncidentModal" aria-label="Close incident editor">×</button>
  </div>

  <div class="incident-edit-layout" data-incident-modal-mode="edit">
    <section class="incident-edit-form stack">
      <div>
        <label>Departments</label>
        <div class="incident-department-picker">
          ${S.departments.map(d=>`<label class="status-select-option">
            <input type="checkbox" name="editDept" value="${d.id}" ${selectedDepartments.has(d.id)?"checked":""}>
            <span>${esc(d.name)}</span>
          </label>`).join("")}
        </div>
      </div>

      <div class="grid2">
        <div><label>Call Type / Nature</label><input id="editCallType" value="${esc(i.call_type)}"></div>
        <div><label>Priority</label><select id="editPriority">
          ${["Standard","Urgent","Critical"].map(p=>`<option ${i.priority===p?"selected":""}>${p}</option>`).join("")}
        </select></div>
      </div>

      <div>
        <label>Change Location Using POI</label>
        <input id="poiSearchEdit" autocomplete="off" placeholder="Search POIs; leave unchanged to keep current location">
        <div id="poiSearchEditResults" class="poi-search-results"></div>
      </div>

      <div class="notice">
        <strong>Selected location</strong><br>
        <span id="editLocationSummary">${esc(layerName(i.map_layer_id)||"Unlayered")}${i.zone_id?` / ${esc(zoneName(i.zone_id))}`:""} · ${esc(i.landmark||"")}</span>
      </div>

      <div><label>Location Description</label><input id="editLandmark" value="${esc(i.landmark||"")}"></div>
      <div><label>Dispatch Notes</label><textarea id="editNotes" rows="7">${esc(i.notes||"")}</textarea></div>
    </section>

    <aside class="incident-edit-context">
      <div class="section-title">Current Call</div>
      ${incidentLocationHtml(i)}
      <div class="incident-edit-context-row"><span>Received</span><strong>${new Date(i.created_at).toLocaleString()}</strong></div>
      <div class="incident-edit-context-row"><span>Elapsed</span><strong data-call-start="${esc(i.created_at)}">00:00</strong></div>
      <div class="incident-edit-context-row"><span>Incident #</span><strong>${esc(i.incident_number)}</strong></div>
      <div class="small muted">The incident number and received timestamp are intentionally not editable.</div>
    </aside>
  </div>

  <div class="incident-modal-footer">
    <button class="btn secondary" id="cancelIncidentEdit">Cancel</button>
    <button class="btn" id="saveIncidentEdit">Save Changes</button>
  </div>`;

  ensureCallTimerTicker();

  document.querySelector("#closeIncidentModal").onclick=()=>closeIncidentModal();

  bindPoiSearch({
    inputId:"poiSearchEdit",
    resultsId:"poiSearchEditResults",
    onSelect:p=>{
      chosen=poiLocationObject(p);
      document.querySelector("#editLandmark").value=p.name;
      document.querySelector("#editLocationSummary").textContent=`${layerName(p.map_layer_id)||"Unlayered"}${p.zone_id?` / ${zoneName(p.zone_id)}`:""} · ${p.name}`;
      focusPoiOnMap(p);
    }
  });

  document.querySelector("#cancelIncidentEdit").onclick=()=>selectIncident(incidentId);

  document.querySelector("#saveIncidentEdit").onclick=async()=>{
    const departments=[...document.querySelectorAll('input[name="editDept"]:checked')].map(x=>x.value);
    if(!departments.length)return alert("Choose at least one department.");

    const callType=document.querySelector("#editCallType").value.trim();
    if(!callType)return alert("Enter a call type / nature.");

    const saveButton=document.querySelector("#saveIncidentEdit");
    saveButton.disabled=true;
    saveButton.textContent="Saving…";

    const {error}=await supabase.rpc("update_incident_v3",{
      p_incident_id:incidentId,
      p_department_ids:departments,
      p_call_type:callType,
      p_priority:document.querySelector("#editPriority").value,
      p_latitude:chosen.latitude,
      p_longitude:chosen.longitude,
      p_map_x:chosen.map_x,
      p_map_y:chosen.map_y,
      p_landmark:document.querySelector("#editLandmark").value.trim(),
      p_notes:document.querySelector("#editNotes").value.trim(),
      p_poi_id:chosen.poi_id||null,
      p_map_layer_id:chosen.map_layer_id||null,
      p_zone_id:chosen.zone_id||null
    });

    saveButton.disabled=false;
    saveButton.textContent="Save Changes";

    if(error)return alert(`Call was not updated.\n\n${error.message}`);

    await loadEventOps();
    refreshDispatchBoards();
    selectIncident(incidentId);
  };
}


/* ---------------- COMMAND CENTER DISPLAY ---------------- */

function commandFilteredIncidents(){
  return S.incidents.filter(i=>incidentMatchesDepartments(i,S.commandDepartmentIds));
}
function commandFilteredUnits(){
  return S.units.filter(u=>S.commandDepartmentIds.includes(u.department_id));
}
function commandPriorityClass(priority){
  const key=String(priority||"").toLowerCase();
  if(key==="critical")return "command-priority-critical";
  if(key==="urgent")return "command-priority-urgent";
  return "command-priority-standard";
}
function commandCallCardsHtml(){
  const incidents=commandFilteredIncidents();
  return incidents.map(i=>{
    const deps=(i.incident_departments||[])
      .map(d=>d.event_departments?.short_name||d.event_departments?.name)
      .filter(Boolean);
    const assigned=(i.incident_units||[])
      .filter(x=>!x.cleared_at)
      .map(link=>{
        const unit=S.units.find(u=>u.id===link.unit_id);
        if(!unit)return "";
        return `<span class="command-unit-chip"><strong>${esc(unit.name)}</strong> · ${esc(String(unit.status||"").replaceAll("_"," "))}${unitTransportDestinationLabel(unit)?` → ${esc(unitTransportDestinationLabel(unit))}`:""}</span>`;
      }).filter(Boolean).join("");

    return `<div class="command-call-card ${commandPriorityClass(i.priority)}">
      <div class="command-call-head">
        <div>
          <div class="command-incident-number">${esc(i.incident_number)}</div>
          <div class="command-call-nature">${esc(i.call_type)}</div>
        </div>
        <div class="command-call-head-right">
          <span class="badge">${esc(i.priority)}</span>
          <span class="command-elapsed" data-call-start="${esc(i.created_at)}">00:00</span>
        </div>
      </div>
      <div class="command-call-location">
        ${i.map_layer_id?`<span class="badge layer-badge">${esc(layerName(i.map_layer_id))}</span>`:""}
        ${i.zone_id?`<span class="badge">${esc(zoneName(i.zone_id))}</span>`:""}
        <strong>${esc(i.landmark||"Mapped location")}</strong>
      </div>
      <div class="command-call-departments">${esc(deps.join(" / "))}</div>
      <div class="command-call-units">${assigned||`<span class="muted">No units assigned</span>`}</div>
    </div>`;
  }).join("")||`<div class="command-empty">No active calls for the selected department filter.</div>`;
}
function renderCommandCallPanel(){
  const host=document.querySelector("#commandCallList");
  if(host)host.innerHTML=commandCallCardsHtml();
  const count=document.querySelector("#commandCallCount");
  if(count)count.textContent=String(commandFilteredIncidents().length);
  updateCallTimers();
}
function commandMapLayer(){
  return S.mapLayers.find(l=>l.id===S.commandActiveMapLayerId&&l.status==="published")||null;
}
function clearCommandMap(){
  S.commandMapGeneration++;
  if(S.commandMap){
    try{S.commandMap.remove();}catch{}
  }
  S.commandMap=null;
  S.commandIncidentLayer=null;
  S.commandUnitLayer=null;
}
function renderCommandIncidentMarkers(){
  if(!S.commandMap||!S.commandIncidentLayer)return;
  S.commandIncidentLayer.clearLayers();
  const layer=commandMapLayer();
  if(!layer)return;

  for(const i of commandFilteredIncidents().filter(i=>!i.map_layer_id||i.map_layer_id===layer.id)){
    if(i.map_x==null||i.map_y==null)continue;
    L.circleMarker(pixelToLeaflet(i.map_x,i.map_y,layer.image_height),{
      radius:10,weight:3,className:`command-incident-marker ${commandPriorityClass(i.priority)}`
    }).addTo(S.commandIncidentLayer)
      .bindTooltip(`<strong>${esc(i.incident_number)}</strong><br>${esc(i.call_type)}<br>${esc(i.landmark||"")}`,{direction:"top"});
  }
}
function renderCommandUnitMarkers(){
  if(!S.commandMap||!S.commandUnitLayer)return;
  S.commandUnitLayer.clearLayers();
  const layer=commandMapLayer();
  if(!layer?.georef_coefficients)return;

  for(const unit of commandFilteredUnits()){
    const location=unitLocation(unit.id);
    if(!location||locationFreshness(location)==="expired")continue;
    if(unitLocationLayerId(unit)!==layer.id)continue;

    let px;
    try{
      px=geoToPixel(Number(location.latitude),Number(location.longitude),layer.georef_coefficients);
    }catch{
      continue;
    }
    if(px.x < -50 || px.y < -50 || px.x > Number(layer.image_width)+50 || px.y > Number(layer.image_height)+50)continue;

    const freshness=locationFreshness(location);
    L.circleMarker(pixelToLeaflet(px.x,px.y,layer.image_height),{
      radius:10,weight:3,
      fillOpacity:freshness==="live"?.95:.5,
      opacity:freshness==="live"?1:.6,
      className:`command-unit-marker command-unit-${freshness}`
    }).addTo(S.commandUnitLayer)
      .bindTooltip(`<strong>${esc(unit.name)}</strong><br>${esc(String(unit.status||"").replaceAll("_"," "))}<br>${esc(locationAgeLabel(location))}${location.accuracy_m!=null?` · ±${Math.round(location.accuracy_m)}m`:""}`,{direction:"top"});
  }
}
async function setupCommandDisplayMap(){
  const host=document.querySelector("#commandMap");
  if(!host)return;

  clearCommandMap();
  const generation=S.commandMapGeneration;
  const layer=commandMapLayer();
  if(!layer?.rendered_image_path){
    host.innerHTML=`<div class="command-map-empty">No published map layer selected.</div>`;
    return;
  }

  host.innerHTML="";
  const url=await storageSigned(layer.rendered_image_path);
  if(generation!==S.commandMapGeneration||!document.querySelector("#commandMap"))return;

  S.commandMap=L.map("commandMap",{
    crs:L.CRS.Simple,minZoom:-4,maxZoom:5,zoomSnap:.25,attributionControl:false,zoomControl:false
  });
  const bounds=[[0,0],[layer.image_height,layer.image_width]];
  L.imageOverlay(url,bounds).addTo(S.commandMap);
  S.commandMap.fitBounds(bounds);

  S.commandIncidentLayer=L.layerGroup().addTo(S.commandMap);
  S.commandUnitLayer=L.layerGroup().addTo(S.commandMap);
  renderCommandIncidentMarkers();
  renderCommandUnitMarkers();
  setTimeout(()=>S.commandMap?.invalidateSize(),50);
}
function commandDisplayDepartmentControls(){
  const allSelected=S.commandDepartmentIds.length===S.departments.length;
  return `<button class="command-filter-chip ${allSelected?"active":""}" data-command-all="true">All</button>`+
    S.departments.map(d=>`
      <button class="command-filter-chip ${S.commandDepartmentIds.includes(d.id)?"active":""}" data-command-dept="${d.id}">
        ${esc(d.short_name||d.name)}
      </button>
    `).join("");
}
function renderCommandDisplayLayout(){
  const content=document.querySelector("#commandDisplayContent");
  if(!content)return;
  const showCalls=S.commandDisplayMode==="calls"||S.commandDisplayMode==="split";
  const showMap=S.commandDisplayMode==="map"||S.commandDisplayMode==="split";

  content.className=`command-display-content mode-${S.commandDisplayMode}`;
  content.innerHTML=`
    ${showCalls?`<section class="command-call-board"><div id="commandCallList">${commandCallCardsHtml()}</div></section>`:""}
    ${showMap?`<section class="command-map-board"><div id="commandMap"></div><div class="command-map-legend"><span><i class="legend-call"></i> Active Call</span><span><i class="legend-unit"></i> Live Unit GPS</span></div></section>`:""}
  `;
  renderCommandCallPanel();
  if(showMap)setupCommandDisplayMap();
}
function updateCommandClock(){
  const el=document.querySelector("#commandClock");
  if(el)el.textContent=new Date().toLocaleTimeString([],{hour:"2-digit",minute:"2-digit",second:"2-digit"});
}
async function refreshCommandDisplayStructure(){
  if(!document.querySelector("#commandDisplayShell"))return;
  const previousDepartments=[...S.commandDepartmentIds];
  const previousMode=S.commandDisplayMode;
  const previousLayer=S.commandActiveMapLayerId;

  try{
    await loadEventOps();
  }catch(error){
    console.warn("Command Display refresh failed",error);
    return;
  }

  S.commandDepartmentIds=normalizeDepartmentSelection(previousDepartments);
  if(!S.commandDepartmentIds.length)S.commandDepartmentIds=S.departments.map(d=>d.id);
  S.commandDisplayMode=previousMode;
  S.commandActiveMapLayerId=S.mapLayers.some(l=>l.id===previousLayer&&l.status==="published")
    ? previousLayer
    : S.mapLayers.find(l=>l.is_default&&l.status==="published")?.id||S.mapLayers.find(l=>l.status==="published")?.id||null;

  const filterHost=document.querySelector("#commandDepartmentFilters");
  if(filterHost)filterHost.innerHTML=commandDisplayDepartmentControls();
  bindCommandDisplayControls();
  renderCommandDisplayLayout();
}
function scheduleCommandDisplayRefresh(){
  if(S.commandRefreshTimer)clearTimeout(S.commandRefreshTimer);
  S.commandRefreshTimer=setTimeout(()=>{
    S.commandRefreshTimer=null;
    refreshCommandDisplayStructure();
  },250);
}
function updateCommandDisplayUnitLocation(payload){
  const row=payload?.new;
  const old=payload?.old;
  if(payload.eventType==="DELETE"){
    const unitId=old?.unit_id;
    if(unitId)S.unitLocations=S.unitLocations.filter(l=>l.unit_id!==unitId);
  }else if(row?.unit_id){
    const index=S.unitLocations.findIndex(l=>l.unit_id===row.unit_id);
    if(index>=0)S.unitLocations[index]=row;else S.unitLocations.push(row);
  }
  renderCommandUnitMarkers();
}
function subscribeCommandDisplay(){
  const ch=supabase.channel(`command-display-${S.eventId}-${Date.now()}`)
    .on("postgres_changes",{event:"*",schema:"public",table:"incidents",filter:`event_id=eq.${S.eventId}`},scheduleCommandDisplayRefresh)
    .on("postgres_changes",{event:"*",schema:"public",table:"incident_units"},scheduleCommandDisplayRefresh)
    .on("postgres_changes",{event:"UPDATE",schema:"public",table:"units",filter:`event_id=eq.${S.eventId}`},payload=>{
      const unit=S.units.find(u=>u.id===payload.new?.id);
      if(unit&&payload.new?.status)unit.status=payload.new.status;
      renderCommandCallPanel();
      renderCommandUnitMarkers();
    })
    .on("postgres_changes",{event:"*",schema:"public",table:"unit_locations"},payload=>updateCommandDisplayUnitLocation(payload))
    .subscribe();
  S.realtime.push(ch);
}
function bindCommandDisplayControls(){
  document.querySelector("[data-command-all]")?.addEventListener("click",()=>{
    S.commandDepartmentIds=S.departments.map(d=>d.id);
    saveCommandDisplayPreferences();
    document.querySelectorAll("[data-command-dept]").forEach(b=>b.classList.add("active"));
    document.querySelector("[data-command-all]")?.classList.add("active");
    renderCommandDisplayLayout();
  });

  document.querySelectorAll("[data-command-dept]").forEach(btn=>{
    btn.onclick=()=>{
      const id=btn.dataset.commandDept;
      const set=new Set(S.commandDepartmentIds);
      if(set.has(id)){
        if(set.size===1)return;
        set.delete(id);
      }else set.add(id);
      S.commandDepartmentIds=[...set];
      saveCommandDisplayPreferences();
      document.querySelectorAll("[data-command-dept]").forEach(b=>b.classList.toggle("active",S.commandDepartmentIds.includes(b.dataset.commandDept)));
      document.querySelector("[data-command-all]")?.classList.toggle("active",S.commandDepartmentIds.length===S.departments.length);
      renderCommandDisplayLayout();
    };
  });
}
async function commandDisplayPage(){
  closeIncidentModal();
  setCommandViewUrl(true);
  cleanupRealtime();
  clearCommandMap();

  try{
    await loadEventOps();
  }catch(error){
    alert(error.message);
    setCommandViewUrl(false);
    return dispatchPage();
  }

  loadCommandDisplayPreferences();

  app.innerHTML=`<div class="command-display-shell" id="commandDisplayShell">
    <header class="command-display-header">
      <div>
        <div class="command-display-brand">CommCenter Pro</div>
        <div class="command-display-event">${esc(S.event?.name||"Event")} · Command Center</div>
      </div>
      <div class="command-display-metrics">
        <div><span>ACTIVE CALLS</span><strong id="commandCallCount">${commandFilteredIncidents().length}</strong></div>
        <div><span>TIME</span><strong id="commandClock"></strong></div>
      </div>
      <div class="command-display-actions">
        <button class="btn secondary" id="commandFullscreen">Full Screen</button>
        <button class="btn secondary" id="commandBack">Back to Dispatch</button>
      </div>
    </header>

    <div class="command-display-controls">
      <div class="command-control-group">
        <span class="command-control-label">Departments</span>
        <div class="command-filter-row" id="commandDepartmentFilters">${commandDisplayDepartmentControls()}</div>
      </div>
      <div class="command-control-group command-mode-controls">
        <span class="command-control-label">View</span>
        <button class="command-mode-button ${S.commandDisplayMode==="calls"?"active":""}" data-command-mode="calls">Calls</button>
        <button class="command-mode-button ${S.commandDisplayMode==="split"?"active":""}" data-command-mode="split">Split</button>
        <button class="command-mode-button ${S.commandDisplayMode==="map"?"active":""}" data-command-mode="map">Map</button>
      </div>
      <div class="command-control-group">
        <span class="command-control-label">Map Layer</span>
        <select id="commandMapLayer">
          ${S.mapLayers.filter(l=>l.status==="published").map(l=>`<option value="${l.id}" ${l.id===S.commandActiveMapLayerId?"selected":""}>${esc(l.name)}</option>`).join("")}
        </select>
      </div>
    </div>

    <main id="commandDisplayContent"></main>
  </div>`;

  document.querySelector("#commandBack").onclick=()=>{setCommandViewUrl(false);dispatchPage();};
  document.querySelector("#commandFullscreen").onclick=async()=>{
    const shell=document.querySelector("#commandDisplayShell");
    try{
      if(!document.fullscreenElement)await shell.requestFullscreen();
      else await document.exitFullscreen();
    }catch(error){
      alert(`Full screen is not available in this browser: ${error.message}`);
    }
  };
  document.querySelectorAll("[data-command-mode]").forEach(btn=>btn.onclick=()=>{
    S.commandDisplayMode=btn.dataset.commandMode;
    saveCommandDisplayPreferences();
    document.querySelectorAll("[data-command-mode]").forEach(b=>b.classList.toggle("active",b.dataset.commandMode===S.commandDisplayMode));
    renderCommandDisplayLayout();
  });
  document.querySelector("#commandMapLayer").onchange=e=>{
    S.commandActiveMapLayerId=e.target.value;
    saveCommandDisplayPreferences();
    if(S.commandDisplayMode!=="calls")setupCommandDisplayMap();
  };

  bindCommandDisplayControls();
  renderCommandDisplayLayout();
  updateCommandClock();
  if(S.commandClockInterval)clearInterval(S.commandClockInterval);
  S.commandClockInterval=setInterval(updateCommandClock,1000);
  ensureCallTimerTicker();
  ensureLocationAgeTicker();
  subscribeCommandDisplay();
}

/* ---------------- EVENT ADMIN ---------------- */

async function eventAdmin(initialTab="setup"){
  closeIncidentModal();
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
        <div><label>New 4-digit PIN</label><input id="newPin" maxlength="4" inputmode="numeric" placeholder="••••"></div>
      </div>
      <label style="margin-top:10px"><input id="accessEnabled" type="checkbox" ${S.event.field_access_enabled?"checked":""}> Field access enabled</label>
      <label style="margin-top:8px"><input id="locationEnabled" type="checkbox" ${S.event.field_location_enabled?"checked":""}> Allow field units to share live GPS location with Dispatch</label>
      <div class="small muted" style="margin-top:5px">Location is opt-in on each field device. This version stores only the latest location, not a route history.</div>
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
        <div><label>Department Name</label><input id="deptName" placeholder="Department name"></div>
        <div><label>Short Name</label><input id="deptShort" placeholder="Short name"></div>
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
        <input id="unitName" placeholder="Unit name">
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
    const locationEnabled=document.querySelector("#locationEnabled").checked;
    if(pin&& !/^\d{4}$/.test(pin))return alert("PIN must be exactly 4 digits.");

    const fieldResult=await supabase.rpc("set_event_field_access",{p_event_id:S.eventId,p_pin:pin||null,p_enabled:enabled});
    if(fieldResult.error){
      document.querySelector("#pinMsg").textContent=fieldResult.error.message;
      return;
    }

    const locationResult=await supabase.rpc("set_event_field_location_enabled",{p_event_id:S.eventId,p_enabled:locationEnabled});
    document.querySelector("#pinMsg").textContent=locationResult.error?locationResult.error.message:"Saved.";
    if(!locationResult.error){await loadEventOps();renderEventSetup();}
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
      <div><label>Venue Name</label><input id="venueName" placeholder="Venue name"></div>
      <div><label>Venue Address</label><input id="venueAddress" placeholder="Venue address"></div>
    `}

    <div><label>Version Notes</label><input id="venueNotes" placeholder="Version notes"></div>

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
  closeIncidentModal();
  const {data,error}=await supabase.from("dispatch_log").select("*").eq("event_id",S.eventId).order("received_time");
  if(error)return alert(error.message);
  app.innerHTML=`<div class="shell">${header(`${esc(S.event?.name||"Event")} · Reports`)}
    <div class="wrap stack">
      <div class="row"><h2>Dispatch Log</h2><div class="nav"><button class="btn secondary" id="backCad">Back to CAD</button><button class="btn" id="downloadCsv">Download CSV</button></div></div>
      <div class="table-wrap"><table><thead><tr>
        <th>Incident</th><th>Received</th><th>Departments</th><th>Nature</th><th>Priority</th><th>Location</th><th>Units</th><th>En Route</th><th>On Scene</th><th>Disposition</th><th>Clear</th>
      </tr></thead><tbody>${(data||[]).map(r=>`<tr>
        <td>${esc(r.incident_number)}</td><td>${fmt(r.received_time)}</td><td>${esc(r.departments||"")}</td><td>${esc(r.call_type)}</td><td>${esc(r.priority)}</td>
        <td>${esc(r.landmark||"")}</td><td>${esc(r.units||"")}</td><td>${fmt(r.first_enroute)}</td><td>${fmt(r.first_onscene)}</td><td>${esc(r.disposition||"")}</td><td>${fmt(r.last_clear||r.closed_at)}</td>
      </tr>`).join("")}</tbody></table></div>
    </div></div>`;
  document.querySelector("#backCad").onclick=()=>dispatchPage();
  document.querySelector("#downloadCsv").onclick=()=>downloadCsv(data||[]);
}
function downloadCsv(rows){
  const cols=["incident_number","received_time","departments","call_type","priority","landmark","latitude","longitude","units","first_enroute","first_onscene","first_transporting","last_clear","disposition","closed_at"];
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
    <div><label>Event ID</label><input id="fieldEventCode" placeholder="Event code"></div>
    <div><label>4-digit access code</label><input id="fieldPin" inputmode="numeric" maxlength="4" placeholder="••••"></div>
    <div><label>Operator name (optional)</label><input id="operatorName" placeholder="Operator name"></div>
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
    .select("*,events(name,field_location_enabled,venue_type),units(name,status,event_id,current_map_layer_id,current_zone_id,current_transport_destination_text,current_transport_treatment_area_id,event_departments(name,status_profile))")
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
  const [{data:fieldMapLayers},{data:fieldZones},{data:fieldTreatmentAreas}]=await Promise.all([
    supabase.from("event_map_layers").select("id,name,level_code,is_default").eq("event_id",S.eventId).eq("active",true).eq("status","published").order("sort_order"),
    supabase.from("event_zones").select("id,map_layer_id,name").eq("event_id",S.eventId).eq("active",true).order("sort_order"),
    supabase.from("ems_treatment_areas").select("id,name,status,accepting_patients").eq("event_id",S.eventId).eq("active",true).order("name")
  ]);
  let emsState=null;
  try{emsState=await loadFieldEmsState(S.eventId,fs.unit_id,incident?.id||null);}catch(err){console.error("Field EMS panel failed to load",err);}
  const fieldIsAmbulance=!!(emsState?.config?.active&&(emsState.config.ems_role==="ambulance"||emsState.config.transport_capable));

  app.innerHTML=`<div class="shell">${header(`${esc(fs.events?.name||"")} · ${esc(fs.units?.event_departments?.name||"")}`)}
    <div class="field-shell stack">
      <div class="card"><div class="small muted">Your unit</div><div class="big">${esc(fs.units?.name)}</div><span class="badge status-${esc(fs.units?.status)}" data-field-unit-status>${esc(fs.units?.status?.replaceAll("_"," "))}</span></div>
      ${incident?`<div class="card assignment"><div class="row"><strong>${esc(incident.incident_number)}</strong><span class="incident-head-meta"><span class="call-timer field-call-timer" title="Elapsed call time" data-call-start="${esc(incident.created_at)}">00:00</span><span class="badge">${esc(incident.priority)}</span></span></div>
        <h2>${esc(incident.call_type)}</h2>${fieldLayer?`<div class="venue-location-line"><span class="badge layer-badge">${esc(fieldLayer.name)}</span>${fieldZone?` <span class="badge">${esc(fieldZone.name)}</span>`:""}</div>`:""}<p>${esc(incident.landmark||"")}<br>
        <span class="small mono">${Number(incident.latitude).toFixed(6)}, ${Number(incident.longitude).toFixed(6)}</span></p><p>${esc(incident.notes||"")}</p>
        <button class="btn secondary block" id="viewFieldMap">View on Event Map</button>
        <div id="fieldMapHolder"></div>
      </div>`:`<div class="card"><strong>No current assignment</strong><p class="muted">Remain available for dispatch.</p></div>`}
      ${fs.events?.field_location_enabled?`<div class="card field-location-card">
        <div class="row">
          <div>
            <div class="section-title">Live Unit Location</div>
            <strong>Share this device's GPS with Dispatch</strong>
          </div>
          <span class="badge ${S.locationWatchId!=null?"gps-sharing-badge":""}" id="fieldLocationBadge">${S.locationWatchId!=null?"SHARING":"OFF"}</span>
        </div>
        <p class="small muted">Your browser will ask for location permission. CommCenter Pro stores only the unit's current location in this version; it does not save a breadcrumb history.</p>
        ${(fieldMapLayers||[]).length>1?`<div class="grid2">
          <div><label>Current Venue Level</label><select id="fieldVenueLayer">
            <option value="">Default / level unknown</option>
            ${(fieldMapLayers||[]).map(l=>`<option value="${l.id}" ${fs.units?.current_map_layer_id===l.id?"selected":""}>${esc(l.name)}</option>`).join("")}
          </select></div>
          <div><label>Current Zone</label><select id="fieldVenueZone">
            <option value="">No zone</option>
            ${(fieldZones||[]).filter(z=>!fs.units?.current_map_layer_id||z.map_layer_id===fs.units.current_map_layer_id).map(z=>`<option value="${z.id}" ${fs.units?.current_zone_id===z.id?"selected":""}>${esc(z.name)}</option>`).join("")}
          </select></div>
        </div><button class="btn secondary block" id="saveFieldVenueLocation">Update Venue Level / Zone</button>`:""}
        <div id="fieldLocationStatus" class="location-status ${S.locationWatchId!=null?"ok":""}">${S.locationWatchId!=null?"Location sharing is active while this page remains visible.":"Location is not being shared."}</div>
        <div class="grid2">
          <button class="btn" id="startLocationSharing" ${S.locationWatchId!=null?"disabled":""}>Start Sharing Location</button>
          <button class="btn secondary" id="stopLocationSharing" ${S.locationWatchId==null?"disabled":""}>Stop Sharing</button>
        </div>
      </div>`:""}
      ${fieldEmsPanelHtml(emsState,incident)}
      <div class="status-buttons">${statuses.map(status=>`<button class="btn field-status-button ${fieldStatusColorClass(status)} ${status===fs.units?.status?"field-status-active":""}" data-status="${esc(status)}" aria-pressed="${status===fs.units?.status?"true":"false"}">${esc(status.replaceAll("_"," "))}</button>`).join("")}</div>
      <div class="card transport-destination-editor ${fs.units?.status==="TRANSPORTING"?"":"hidden"}" id="fieldTransportDestinationPanel">
        <div class="section-title">Transport Destination</div>
        ${emsState?.config?.active&&(emsState.config.ems_role==="ambulance"||emsState.config.transport_capable)?`
          <label>Destination facility</label>
          <input id="fieldTransportFacility" value="${esc(fs.units?.current_transport_destination_text||"")}" placeholder="Destination facility">
        `:`
          <label>Treatment area destination</label>
          <select id="fieldTransportTreatmentArea">
            <option value="">Choose treatment area</option>
            ${(fieldTreatmentAreas||[]).filter(a=>a.status!=="CLOSED").map(a=>`
              <option value="${a.id}" ${fs.units?.current_transport_treatment_area_id===a.id?"selected":""}>${esc(a.name)} · ${esc(a.status)}</option>
            `).join("")}
          </select>
        `}
        <div class="grid2">
          <button class="btn" id="confirmFieldTransport">${fs.units?.status==="TRANSPORTING"?"Update Destination":"Set Transporting"}</button>
          <button class="btn secondary" id="cancelFieldTransport">Cancel</button>
        </div>
        ${!fieldIsAmbulance&&fs.units?.status==="TRANSPORTING"&&fs.units?.current_transport_treatment_area_id&&incident?`
          <div class="treatment-arrival-action field-treatment-arrival">
            <div>
              <div class="section-title">Treatment Area Arrival</div>
              <strong>${esc((fieldTreatmentAreas||[]).find(a=>a.id===fs.units.current_transport_treatment_area_id)?.name||"Treatment Area")}</strong>
              <div class="small muted">Use this when the unit and patient have physically arrived.</div>
            </div>
            <button class="btn good block" id="fieldArriveTreatmentArea">Arrived at Treatment Area</button>
          </div>
        `:""}
      </div>
      <div class="notice ${navigator.onLine?"ok":""}">${navigator.onLine?"Connected":"Offline — CAD changes cannot reach dispatch until connectivity returns."}</div>
      <button class="btn secondary" id="downloadOffline">Download Event Map for Offline Use</button>
      <div id="offlineStatus" class="small muted"></div>
      <button class="btn secondary" id="changeUnit">Change Unit</button><button class="btn secondary" id="leaveEvent">Leave Event</button>
    </div></div>`;
  ensureCallTimerTicker();

  const setFieldStatus=async(requested,{destinationText=null,treatmentAreaId=null}={})=>{
    const {error}=await supabase.rpc("field_set_unit_status_v2",{
      p_unit_id:fs.unit_id,
      p_status:requested,
      p_incident_id:incident?.id||null,
      p_client_time:new Date().toISOString(),
      p_transport_destination_text:destinationText,
      p_transport_treatment_area_id:treatmentAreaId
    });
    if(error){
      alert(error.message);
      return false;
    }

    fs.units.status=requested;
    fs.units.current_transport_destination_text=requested==="TRANSPORTING"?destinationText:null;
    fs.units.current_transport_treatment_area_id=requested==="TRANSPORTING"?treatmentAreaId:null;
    updateFieldUnitStatusUI(requested);
    return true;
  };

  document.querySelectorAll("[data-status]").forEach(b=>b.onclick=async()=>{
    const requested=b.dataset.status;

    if(requested==="TRANSPORTING"){
      document.querySelector("#fieldTransportDestinationPanel")?.classList.remove("hidden");
      document.querySelector(fieldIsAmbulance?"#fieldTransportFacility":"#fieldTransportTreatmentArea")?.focus();
      return;
    }

    if(requested==="AVAILABLE"&&fieldIsAmbulance&&incident?.id){
      const handled=await maybePromptAmbulanceTransportOutcome({
        unitId:fs.unit_id,
        incidentId:incident.id,
        unitName:fs.units?.name,
        incidentNumber:incident.incident_number,
        onComplete:async()=>fieldUnitCad(),
        onCancel:()=>{}
      });
      if(handled)return;
    }

    if(requested===fs.units.status)return;
    b.disabled=true;
    const ok=await setFieldStatus(requested);
    b.disabled=false;
    if(ok)document.querySelector("#fieldTransportDestinationPanel")?.classList.add("hidden");
  });

  document.querySelector("#cancelFieldTransport")?.addEventListener("click",()=>{
    if(fs.units.status!=="TRANSPORTING")document.querySelector("#fieldTransportDestinationPanel")?.classList.add("hidden");
  });

  document.querySelector("#confirmFieldTransport")?.addEventListener("click",async()=>{
    const destinationText=fieldIsAmbulance?document.querySelector("#fieldTransportFacility").value.trim():null;
    const treatmentAreaId=fieldIsAmbulance?null:(document.querySelector("#fieldTransportTreatmentArea").value||null);
    if(fieldIsAmbulance&&!destinationText)return alert("Enter the destination facility.");
    if(!fieldIsAmbulance&&!treatmentAreaId)return alert("Choose the treatment area destination.");

    const button=document.querySelector("#confirmFieldTransport");
    button.disabled=true;
    const ok=await setFieldStatus("TRANSPORTING",{destinationText,treatmentAreaId});
    button.disabled=false;
    if(ok)fieldUnitCad();
  });

  document.querySelector("#fieldArriveTreatmentArea")?.addEventListener("click",async()=>{
    if(!incident)return;
    const areaName=(fieldTreatmentAreas||[]).find(a=>a.id===fs.units?.current_transport_treatment_area_id)?.name||"the treatment area";
    if(!confirm(`Confirm arrival at ${areaName} with the patient?`))return;

    const button=document.querySelector("#fieldArriveTreatmentArea");
    button.disabled=true;
    button.textContent="Recording Arrival…";

    const {error}=await supabase.rpc("unit_arrive_treatment_area",{
      p_unit_id:fs.unit_id,
      p_incident_id:incident.id
    });

    if(error){
      button.disabled=false;
      button.textContent="Arrived at Treatment Area";
      return alert(error.message);
    }

    fieldUnitCad();
  });
  if(fs.events?.field_location_enabled){
    bindFieldLocationControls(fs,fieldMapLayers||[],fieldZones||[]);
  }
  bindFieldEmsPanel(emsState,{eventId:S.eventId,unitId:fs.unit_id,incident,refresh:()=>fieldUnitCad()});
  document.querySelector("#downloadOffline").onclick=()=>downloadOfflineEventData();
  getOfflineEvent(S.eventId).then(x=>{if(x)document.querySelector("#offlineStatus").textContent=`Offline package saved ${new Date(x.savedAt).toLocaleString()}`;}).catch(()=>{});
  document.querySelector("#changeUnit").onclick=async()=>{await stopFieldLocationSharing(fs.unit_id,{notifyServer:true});await supabase.rpc("field_release_unit",{p_field_session_id:fs.id});fieldUnitPicker();};
  document.querySelector("#leaveEvent").onclick=leaveField;
  if(incident)document.querySelector("#viewFieldMap").onclick=()=>showFieldMap(incident);
  subscribeField(fs.unit_id);
}

function fieldLocationPreferenceKey(eventId,unitId){
  return `commcenter-live-location:${eventId}:${unitId}`;
}

function updateFieldLocationUi({message,sharing,accuracy=null,error=false}){
  const badge=document.querySelector("#fieldLocationBadge");
  const status=document.querySelector("#fieldLocationStatus");
  const start=document.querySelector("#startLocationSharing");
  const stop=document.querySelector("#stopLocationSharing");

  if(badge){
    badge.textContent=sharing?"SHARING":"OFF";
    badge.classList.toggle("gps-sharing-badge",!!sharing);
  }
  if(status){
    status.textContent=`${message||""}${accuracy!=null?` · accuracy ±${Math.round(accuracy)}m`:""}`;
    status.classList.toggle("ok",!!sharing&&!error);
    status.classList.toggle("error",!!error);
  }
  if(start)start.disabled=!!sharing;
  if(stop)stop.disabled=!sharing;
}

async function sendFieldLocation(unitId,position){
  if(S.locationWriteInFlight)return;

  const now=Date.now();
  const coords=position.coords;
  const current={lat:Number(coords.latitude),lon:Number(coords.longitude)};
  const elapsed=now-(S.locationLastSentAt||0);
  const moved=S.locationLastSent
    ? distanceMeters(S.locationLastSent.lat,S.locationLastSent.lon,current.lat,current.lon)
    : Infinity;

  // High-frequency GPS callbacks are intentionally throttled. Send immediately
  // the first time, then at most about every 5 seconds while moving, with a
  // 15-second heartbeat even when stationary.
  if(S.locationLastSentAt && elapsed<5000)return;
  if(S.locationLastSent && moved<3 && elapsed<15000)return;

  S.locationWriteInFlight=true;
  try{
    const {error}=await supabase.rpc("field_update_unit_location",{
      p_unit_id:unitId,
      p_latitude:current.lat,
      p_longitude:current.lon,
      p_accuracy_m:Number.isFinite(coords.accuracy)?Number(coords.accuracy):null,
      p_altitude_m:Number.isFinite(coords.altitude)?Number(coords.altitude):null,
      p_heading_deg:Number.isFinite(coords.heading)?Number(coords.heading):null,
      p_speed_mps:Number.isFinite(coords.speed)?Number(coords.speed):null,
      p_client_time:new Date(position.timestamp||Date.now()).toISOString()
    });
    if(error)throw error;

    S.locationLastSentAt=now;
    S.locationLastSent=current;
    updateFieldLocationUi({
      message:"Location shared with Dispatch",
      sharing:true,
      accuracy:coords.accuracy
    });
  }catch(error){
    console.error("Field location update failed",error);
    updateFieldLocationUi({
      message:`Location could not be sent: ${error.message}`,
      sharing:S.locationWatchId!=null,
      error:true
    });
  }finally{
    S.locationWriteInFlight=false;
  }
}

function fieldLocationErrorMessage(error){
  if(error?.code===1)return "Location permission was denied. Allow location access for CommCenter Pro in your browser/site settings.";
  if(error?.code===2)return "This device could not determine its current location.";
  if(error?.code===3)return "Location lookup timed out. Try again where the device has a better GPS/Wi-Fi/cellular fix.";
  return error?.message||"Location is unavailable.";
}

async function startFieldLocationSharing(unitId){
  if(!window.isSecureContext){
    updateFieldLocationUi({message:"Live location requires HTTPS.",sharing:false,error:true});
    return;
  }
  if(!navigator.geolocation){
    updateFieldLocationUi({message:"This browser does not provide the Geolocation API.",sharing:false,error:true});
    return;
  }
  if(S.locationWatchId!=null)return;

  updateFieldLocationUi({message:"Waiting for browser location permission / GPS fix…",sharing:true});

  S.locationLastSentAt=0;
  S.locationLastSent=null;

  S.locationWatchId=navigator.geolocation.watchPosition(
    position=>sendFieldLocation(unitId,position),
    error=>{
      const message=fieldLocationErrorMessage(error);
      if(error?.code===1){
        if(S.locationWatchId!=null){
          navigator.geolocation.clearWatch(S.locationWatchId);
          S.locationWatchId=null;
        }
        try{localStorage.removeItem(fieldLocationPreferenceKey(S.eventId,unitId));}catch{}
      }
      updateFieldLocationUi({message,sharing:S.locationWatchId!=null,error:true});
    },
    {
      enableHighAccuracy:true,
      maximumAge:5000,
      timeout:15000
    }
  );

  try{localStorage.setItem(fieldLocationPreferenceKey(S.eventId,unitId),"1");}catch{}
}

async function stopFieldLocationSharing(unitId,{notifyServer=true}={}){
  if(S.locationWatchId!=null && navigator.geolocation){
    navigator.geolocation.clearWatch(S.locationWatchId);
  }
  S.locationWatchId=null;
  S.locationLastSentAt=0;
  S.locationLastSent=null;
  S.locationWriteInFlight=false;

  try{localStorage.removeItem(fieldLocationPreferenceKey(S.eventId,unitId));}catch{}

  if(notifyServer&&unitId){
    const {error}=await supabase.rpc("field_stop_unit_location",{p_unit_id:unitId});
    if(error)console.warn("Could not clear field unit location",error);
  }

  updateFieldLocationUi({message:"Location sharing is off.",sharing:false});
}

function bindFieldLocationControls(fs,mapLayers,zones){
  document.querySelector("#startLocationSharing")?.addEventListener("click",()=>startFieldLocationSharing(fs.unit_id));
  document.querySelector("#stopLocationSharing")?.addEventListener("click",()=>stopFieldLocationSharing(fs.unit_id,{notifyServer:true}));

  const layerSelect=document.querySelector("#fieldVenueLayer");
  const zoneSelect=document.querySelector("#fieldVenueZone");

  if(layerSelect&&zoneSelect){
    layerSelect.onchange=()=>{
      const layerId=layerSelect.value;
      zoneSelect.innerHTML=`<option value="">No zone</option>${zones.filter(z=>z.map_layer_id===layerId).map(z=>`<option value="${z.id}">${esc(z.name)}</option>`).join("")}`;
    };

    document.querySelector("#saveFieldVenueLocation").onclick=async()=>{
      const layerId=layerSelect.value||null;
      const zoneId=zoneSelect.value||null;
      const {error}=await supabase.rpc("field_set_unit_venue_location",{
        p_unit_id:fs.unit_id,
        p_map_layer_id:layerId,
        p_zone_id:zoneId
      });
      if(error)return alert(error.message);

      fs.units.current_map_layer_id=layerId;
      fs.units.current_zone_id=zoneId;
      updateFieldLocationUi({
        message:layerId?`Venue level updated to ${mapLayers.find(l=>l.id===layerId)?.name||"selected level"}.`:"Venue level set to default / unknown.",
        sharing:S.locationWatchId!=null
      });
    };
  }

  // If this device was sharing before a field-page rerender, the existing
  // watcher remains active. Browser refreshes are different: the page must
  // reacquire geolocation and the browser remains in control of permission.
  if(S.locationWatchId!=null){
    updateFieldLocationUi({message:"Location sharing is active while this page remains visible.",sharing:true});
  }
}

function fieldStatusColorClass(status){
  const key=String(status||"").toUpperCase();
  if(["AVAILABLE","CLEAR","COMPLETE"].includes(key))return "field-status-green";
  if(["ASSIGNED","RESPONDING","EN_ROUTE","RETURNING"].includes(key))return "field-status-blue";
  if(["ON_SCENE","WORKING","LOADING"].includes(key))return "field-status-amber";
  if(["TRANSPORTING","AT_HOSPITAL"].includes(key))return "field-status-purple";
  if(["OUT_OF_SERVICE","OOS"].includes(key))return "field-status-red";
  return "field-status-neutral";
}

function updateFieldUnitStatusUI(status){
  const badge=document.querySelector("[data-field-unit-status]");
  if(badge){
    [...badge.classList].filter(c=>c.startsWith("status-")).forEach(c=>badge.classList.remove(c));
    badge.classList.add(`status-${status}`);
    badge.textContent=String(status||"").replaceAll("_"," ");
  }

  document.querySelectorAll("[data-status]").forEach(btn=>{
    const active=btn.dataset.status===status;
    btn.classList.toggle("field-status-active",active);
    btn.setAttribute("aria-pressed",active?"true":"false");

    // Keep every option lightly color-coded, while the current status receives
    // the strong filled treatment. This makes the selected state unmistakable.
    [
      "field-status-green","field-status-blue","field-status-amber",
      "field-status-purple","field-status-red","field-status-neutral"
    ].forEach(c=>btn.classList.remove(c));
    btn.classList.add(fieldStatusColorClass(btn.dataset.status));
  });
}


async function downloadOfflineEventData(){
  const status=document.querySelector("#offlineStatus");
  try{
    status.textContent="Downloading venue map package…";

    const [{data:layers,error:layersErr},{data:pois,error:poisErr},{data:zones,error:zonesErr}]=await Promise.all([
      supabase.from("event_map_layers").select("*").eq("event_id",S.eventId).eq("active",true).eq("status","published").order("sort_order"),
      supabase.from("event_pois").select("id,name,category,latitude,longitude,map_x,map_y,map_layer_id,zone_id,notes").eq("event_id",S.eventId).eq("active",true),
      supabase.from("event_zones").select("*").eq("event_id",S.eventId).eq("active",true)
    ]);

    if(layersErr)throw layersErr;
    if(poisErr)throw poisErr;
    if(zonesErr)throw zonesErr;
    if(!(layers||[]).length)throw new Error("No published map layers.");

    const offlineLayers=[];
    for(const layer of layers){
      status.textContent=`Downloading ${layer.name}…`;
      const {data:mapBlob,error}=await supabase.storage.from("event-assets").download(layer.rendered_image_path);
      if(error)throw error;
      offlineLayers.push({meta:layer,mapBlob});
    }

    await saveOfflineEvent({
      eventId:S.eventId,
      savedAt:new Date().toISOString(),
      layers:offlineLayers,
      pois:pois||[],
      zones:zones||[]
    });

    status.textContent=`Saved offline: ${offlineLayers.length} map layer${offlineLayers.length===1?"":"s"}.`;
  }catch(err){
    status.textContent=`Offline download failed: ${err.message}`;
  }
}


async function showFieldMap(incident){
  const holder=document.querySelector("#fieldMapHolder");
  holder.innerHTML=`<div id="fieldLayerName" class="small muted" style="margin-top:8px"></div><div id="fieldMap" style="height:420px;margin-top:6px;border-radius:10px;overflow:hidden"></div><div id="fieldMapReadout" class="small muted" style="margin-top:6px"></div>`;

  let m=null,url=null;
  const targetLayerId=incident.map_layer_id||null;

  try{
    if(navigator.onLine){
      let q=supabase.from("event_map_layers").select("*").eq("event_id",S.eventId).eq("status","published");
      q=targetLayerId?q.eq("id",targetLayerId):q.eq("is_default",true);
      const {data}=await q.limit(1).maybeSingle();
      if(data?.rendered_image_path){
        m=data;
        url=await storageSigned(m.rendered_image_path);
      }
    }
  }catch{}

  const offline=await getOfflineEvent(S.eventId).catch(()=>null);
  if(!m&&offline?.layers?.length){
    const item=offline.layers.find(x=>x.meta.id===targetLayerId)||offline.layers.find(x=>x.meta.is_default)||offline.layers[0];
    m=item.meta;
    url=URL.createObjectURL(item.mapBlob);
  }

  if(!m||!url)return alert("No published map layer is available. Download the event map while connected.");

  document.querySelector("#fieldLayerName").textContent=`Map layer: ${m.name}${incident.zone_id?` · ${offline?.zones?.find(z=>z.id===incident.zone_id)?.name||""}`:""}`;

  const map=L.map("fieldMap",{crs:L.CRS.Simple,minZoom:-4,maxZoom:5,attributionControl:false});
  L.imageOverlay(url,[[0,0],[m.image_height,m.image_width]]).addTo(map);

  if(incident.map_x!=null&&incident.map_y!=null){
    const pt=pixelToLeaflet(incident.map_x,incident.map_y,m.image_height);
    L.marker(pt,{icon:fieldIncidentMapIcon()}).addTo(map).bindPopup(`${esc(incident.incident_number)}<br>${esc(incident.landmark||"")}`).openPopup();
    map.setView(pt,0);
  }else{
    map.fitBounds([[0,0],[m.image_height,m.image_width]]);
  }

  if(m.georef_coefficients){
    map.on("click",e=>{
      const px=leafletToPixel(e.latlng,m.image_height);
      const geo=pixelToGeo(px.x,px.y,m.georef_coefficients);
      document.querySelector("#fieldMapReadout").textContent=`${m.name} · ${geo.lat.toFixed(6)}, ${geo.lon.toFixed(6)}`;
    });
  }
}

async function leaveField(){
  if(S.fieldSession?.unit_id)await stopFieldLocationSharing(S.fieldSession.unit_id,{notifyServer:true});
  if(S.fieldSession?.id)await supabase.rpc("field_end_session",{p_field_session_id:S.fieldSession.id});
  await supabase.auth.signOut();S.mode=null;reset();clearNavigationState();route();
}

/* ---------------- REALTIME / RESET ---------------- */

async function refreshDispatchStructure(){
  // Never destroy an editor that contains unsaved dispatcher input.
  if(S.incidentModalMode==="edit"&&document.querySelector("[data-incident-modal-mode='edit']")){
    const footer=document.querySelector(".incident-modal-footer");
    if(footer&&!document.querySelector("#incidentExternalUpdate")){
      footer.insertAdjacentHTML("afterbegin",`<div class="notice" id="incidentExternalUpdate">Other CAD data changed while you are editing. Your unsaved fields have been preserved.</div>`);
    }
    return;
  }

  const reopenIncidentId=S.openIncidentId;
  const reopenUnitId=S.openUnitId;
  await loadEventOps();
  refreshDispatchBoards();

  if(reopenUnitId&&S.units.some(u=>u.id===reopenUnitId)){
    selectUnit(reopenUnitId);
  }else if(reopenIncidentId&&S.incidents.some(i=>i.id===reopenIncidentId)){
    selectIncident(reopenIncidentId);
  }else if(reopenIncidentId||reopenUnitId){
    closeIncidentModal();
  }
}

function subscribeDispatch(){
  const ch=supabase.channel(`event-${S.eventId}-${Date.now()}`)
    // Unit status changes are extremely frequent. Update only the matching unit
    // controls; never rebuild the CAD/map or destroy a form in progress.
    .on("postgres_changes",{event:"UPDATE",schema:"public",table:"units",filter:`event_id=eq.${S.eventId}`},payload=>{
      if(payload.new?.id&&payload.new?.status){
        updateDispatcherUnitStatusUI(payload.new.id,payload.new.status);
      }
    })
    // Structural changes refresh the call/unit boards while preserving an open
    // incident modal. If the call editor has unsaved changes, the refresh is
    // deferred rather than destroying dispatcher input.
    .on("postgres_changes",{event:"*",schema:"public",table:"incidents",filter:`event_id=eq.${S.eventId}`},()=>refreshDispatchStructure())
    .on("postgres_changes",{event:"*",schema:"public",table:"incident_units"},()=>refreshDispatchStructure())
    // GPS changes update only the unit's map marker/readout.
    .on("postgres_changes",{event:"*",schema:"public",table:"unit_locations"},payload=>updateDispatcherUnitLocation(payload))
    .on("postgres_changes",{event:"INSERT",schema:"public",table:"event_pois",filter:`event_id=eq.${S.eventId}`},payload=>handleRealtimePoiInsert(payload))
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
    .on("postgres_changes",{event:"*",schema:"public",table:"ems_encounters",filter:`event_id=eq.${S.eventId}`},()=>fieldUnitCad())
    .subscribe();

  S.realtime.push(ch);
}
function cleanupRealtime(){
  S.realtime.forEach(ch=>supabase.removeChannel(ch));S.realtime=[];
  S.unitLocationMarkers.clear();
  if(S.map){try{S.map.remove()}catch{}}S.map=null;
  clearCommandMap();
  if(S.commandRefreshTimer){clearTimeout(S.commandRefreshTimer);S.commandRefreshTimer=null;}
  if(S.commandClockInterval){clearInterval(S.commandClockInterval);S.commandClockInterval=null;}
}
function reset(){
  if(S.locationWatchId!=null&&navigator.geolocation){
    navigator.geolocation.clearWatch(S.locationWatchId);
  }
  S.locationWatchId=null;
  S.locationLastSentAt=0;
  S.locationLastSent=null;
  S.locationWriteInFlight=false;
  S.unitLocations=[];
  S.unitLocationMarkers.clear();
  S.emsUnitConfigs=[];
  S.treatmentAreas=[];
  S.dispatchLayout=null;
  S.dispatchDepartmentIds=[];
  S.commandDepartmentIds=[];
  S.commandDisplayMode="calls";
  S.commandActiveMapLayerId=null;
  S.mapPickMode=null;
  S.pendingIncidentDraft=null;
  S.openUnitId=null;
  closeIncidentModal();
  S.orgId=null;S.eventId=null;S.event=null;S.fieldSession=null;S.activeMapLayerId=null;
}

init();
