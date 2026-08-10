let googleMapsLoadPromise=null;

const esc=(value="")=>String(value).replace(/[&<>"']/g,char=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[char]));

function metersBetween(a,b){
  if(!a||!b)return Infinity;
  const lat1=Number(a.lat??a.latitude), lon1=Number(a.lng??a.lon??a.longitude);
  const lat2=Number(b.lat??b.latitude), lon2=Number(b.lng??b.lon??b.longitude);
  if(![lat1,lon1,lat2,lon2].every(Number.isFinite))return Infinity;
  const r=6371000;
  const p1=lat1*Math.PI/180, p2=lat2*Math.PI/180;
  const dp=(lat2-lat1)*Math.PI/180;
  const dl=(lon2-lon1)*Math.PI/180;
  const h=Math.sin(dp/2)**2+Math.cos(p1)*Math.cos(p2)*Math.sin(dl/2)**2;
  return 2*r*Math.asin(Math.min(1,Math.sqrt(h)));
}

function formatDistance(meters){
  if(!Number.isFinite(meters))return "";
  const feet=meters*3.28084;
  if(feet<1000)return `${Math.max(1,Math.round(feet))} ft`;
  return `${(meters/1609.344).toFixed(meters<1609.344?2:1)} mi`;
}

function formatDuration(ms){
  if(!Number.isFinite(ms))return "";
  const minutes=Math.max(1,Math.round(ms/60000));
  if(minutes<60)return `${minutes} min`;
  const hours=Math.floor(minutes/60);
  const remainder=minutes%60;
  return `${hours} hr${hours===1?"":"s"}${remainder?` ${remainder} min`:""}`;
}

function normalizeLocation(location){
  if(!location)return null;
  const lat=Number(location.lat??location.latitude);
  const lng=Number(location.lng??location.lon??location.longitude);
  if(!Number.isFinite(lat)||!Number.isFinite(lng))return null;
  return {lat,lng};
}

export function googleNavigationConfigured(){
  return !!String(import.meta.env.VITE_GOOGLE_MAPS_API_KEY||"").trim();
}

export function googleNavigationApiKey(){
  return String(import.meta.env.VITE_GOOGLE_MAPS_API_KEY||"").trim();
}

export async function loadGoogleMaps(apiKey=googleNavigationApiKey()){
  if(window.google?.maps?.importLibrary)return window.google.maps;
  if(!apiKey)throw new Error("Google navigation is not configured. Add VITE_GOOGLE_MAPS_API_KEY to the Netlify environment.");
  if(googleMapsLoadPromise)return googleMapsLoadPromise;

  googleMapsLoadPromise=new Promise((resolve,reject)=>{
    const callback=`__commcenterGoogleMaps_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    const script=document.createElement("script");
    script.dataset.commcenterGoogleMaps="1";
    script.async=true;
    script.defer=true;

    const cleanup=()=>{
      try{delete window[callback];}catch{window[callback]=undefined;}
    };

    window[callback]=()=>{
      cleanup();
      if(window.google?.maps?.importLibrary)resolve(window.google.maps);
      else reject(new Error("Google Maps loaded but the Maps JavaScript API is unavailable."));
    };

    script.onerror=()=>{
      cleanup();
      googleMapsLoadPromise=null;
      reject(new Error("Google Maps could not be loaded. Check the API key, API restrictions, billing, and internet connection."));
    };

    const params=new URLSearchParams({
      key:apiKey,
      loading:"async",
      v:"weekly",
      callback,
      auth_referrer_policy:"origin"
    });
    script.src=`https://maps.googleapis.com/maps/api/js?${params.toString()}`;
    document.head.appendChild(script);
  });

  return googleMapsLoadPromise;
}

function createAffineOverlayClass(){
  return class CommCenterAffineMapOverlay extends google.maps.OverlayView{
    constructor({map,url,width,height,coefficients,opacity=.58}){
      super();
      this.url=url;
      this.width=Number(width);
      this.height=Number(height);
      this.coefficients=coefficients;
      this.opacity=opacity;
      this.div=null;
      this.img=null;
      this.setMap(map);
    }

    pixelToGeo(x,y){
      const lat=this.coefficients?.lat;
      const lon=this.coefficients?.lon;
      if(!lat||!lon)return null;
      return {
        lat:Number(lat[0])+Number(lat[1])*x+Number(lat[2])*y,
        lng:Number(lon[0])+Number(lon[1])*x+Number(lon[2])*y
      };
    }

    onAdd(){
      const div=document.createElement("div");
      div.className="commcenter-google-event-overlay";
      div.style.position="absolute";
      div.style.left="0";
      div.style.top="0";
      div.style.width="0";
      div.style.height="0";
      div.style.pointerEvents="none";

      const img=document.createElement("img");
      img.src=this.url;
      img.alt="";
      img.draggable=false;
      img.style.position="absolute";
      img.style.left="0";
      img.style.top="0";
      img.style.width=`${this.width}px`;
      img.style.height=`${this.height}px`;
      img.style.maxWidth="none";
      img.style.transformOrigin="0 0";
      img.style.opacity=String(this.opacity);
      img.style.pointerEvents="none";
      img.style.userSelect="none";

      div.appendChild(img);
      this.div=div;
      this.img=img;
      this.getPanes()?.overlayLayer?.appendChild(div);
    }

    draw(){
      if(!this.img||!this.width||!this.height)return;
      const projection=this.getProjection();
      if(!projection)return;

      const nw=this.pixelToGeo(0,0);
      const ne=this.pixelToGeo(this.width,0);
      const sw=this.pixelToGeo(0,this.height);
      if(!nw||!ne||!sw)return;

      const p0=projection.fromLatLngToDivPixel(nw);
      const px=projection.fromLatLngToDivPixel(ne);
      const py=projection.fromLatLngToDivPixel(sw);
      if(!p0||!px||!py)return;

      const a=(px.x-p0.x)/this.width;
      const b=(px.y-p0.y)/this.width;
      const c=(py.x-p0.x)/this.height;
      const d=(py.y-p0.y)/this.height;
      const e=p0.x;
      const f=p0.y;
      this.img.style.transform=`matrix(${a},${b},${c},${d},${e},${f})`;
    }

    setOpacity(value){
      this.opacity=Math.max(0,Math.min(1,Number(value)));
      if(this.img)this.img.style.opacity=String(this.opacity);
    }

    onRemove(){
      if(this.div?.parentNode)this.div.parentNode.removeChild(this.div);
      this.div=null;
      this.img=null;
    }
  };
}

function routeStepHtml(route){
  const steps=(route?.legs||[]).flatMap(leg=>leg.steps||[]);
  if(!steps.length)return `<div class="small muted">Google did not return turn-by-turn steps for this route.</div>`;
  return steps.slice(0,8).map((step,index)=>{
    const distance=step.localizedValues?.distance||formatDistance(step.distanceMeters);
    const duration=step.localizedValues?.staticDuration||formatDuration(step.staticDurationMillis);
    return `<div class="field-nav-step">
      <div class="field-nav-step-number">${index+1}</div>
      <div>
        <strong>${esc(step.instructions||step.maneuver||"Continue")}</strong>
        <div class="small muted">${esc([distance,duration].filter(Boolean).join(" · "))}</div>
      </div>
    </div>`;
  }).join("");
}

export async function createGoogleFieldNavigation({
  host,
  destination,
  initialLocation,
  eventOverlay=null,
  incidentNumber="Incident",
  incidentLocation="",
  unitName="Your unit",
  defaultMode="WALKING",
  getFreshLocation=null,
  watchDeviceLocation=false,
  onLocalLocation=null,
  onClose=null
}){
  if(!host)throw new Error("Navigation container is unavailable.");
  const destinationPoint=normalizeLocation(destination);
  if(!destinationPoint)throw new Error("This incident does not have a georeferenced destination for navigation.");

  const apiKey=googleNavigationApiKey();
  if(!apiKey)throw new Error("Google navigation is not configured. Add VITE_GOOGLE_MAPS_API_KEY to Netlify first.");
  if(!navigator.onLine)throw new Error("Google navigation requires an internet connection. The Event Map remains available offline.");

  host.innerHTML=`<div class="field-navigation-shell">
    <div class="field-navigation-toolbar">
      <div>
        <div class="section-title">NAVIGATE TO CALL</div>
        <strong>${esc(incidentNumber)}</strong>${incidentLocation?`<div class="small muted">${esc(incidentLocation)}</div>`:""}
      </div>
      <div class="field-navigation-controls">
        <label class="field-navigation-mode-label">Mode
          <select id="fieldNavigationMode">
            <option value="WALKING" ${defaultMode==="WALKING"?"selected":""}>Walking</option>
            <option value="DRIVING" ${defaultMode==="DRIVING"?"selected":""}>Driving</option>
            <option value="BICYCLING" ${defaultMode==="BICYCLING"?"selected":""}>Bicycling</option>
          </select>
        </label>
        <button class="btn secondary compact" id="fieldNavigationFollow">Follow Me: On</button>
        <button class="btn secondary compact" id="fieldNavigationOverview">Overview</button>
        <button class="btn secondary compact" id="fieldNavigationRecalculate">Recalculate</button>
        ${eventOverlay?`<button class="btn secondary compact" id="fieldNavigationOverlayToggle">Event Overlay: On</button>`:""}
        <button class="btn secondary compact" id="fieldNavigationClose">Close</button>
      </div>
    </div>
    <div id="fieldNavigationMap" class="field-navigation-map" aria-label="Google navigation map"></div>
    <div id="fieldNavigationSummary" class="field-navigation-summary">Loading Google Maps…</div>
    <div id="fieldNavigationWarnings"></div>
    <div id="fieldNavigationSteps" class="field-navigation-steps"></div>
    <div class="small muted field-navigation-note">Google route guidance may not know temporary festival fences, closures, credential gates, or emergency-only access routes. Follow event operations instructions when they conflict with Google routing.</div>
  </div>`;

  await loadGoogleMaps(apiKey);
  const [{Map},{Route}]=await Promise.all([
    google.maps.importLibrary("maps"),
    google.maps.importLibrary("routes")
  ]);

  let destroyed=false;
  let follow=true;
  let overlayVisible=true;
  let mode=String(defaultMode||"WALKING").toUpperCase();
  let currentLocation=normalizeLocation(initialLocation);
  let lastRouteOrigin=null;
  let lastRouteAt=0;
  let routePolylines=[];
  let latestRoute=null;
  let rerouteTimer=null;
  let localWatchId=null;

  const map=new Map(document.querySelector("#fieldNavigationMap"),{
    center:currentLocation||destinationPoint,
    zoom:18,
    mapTypeControl:false,
    streetViewControl:false,
    fullscreenControl:false,
    clickableIcons:false,
    gestureHandling:"greedy",
    mapTypeId:"roadmap"
  });

  const callCircle=new google.maps.Circle({
    map,
    center:destinationPoint,
    radius:7,
    strokeColor:"#991b1b",
    strokeOpacity:1,
    strokeWeight:3,
    fillColor:"#ef4444",
    fillOpacity:.95,
    zIndex:60
  });

  let unitCircle=null;
  let accuracyCircle=null;
  let affineOverlay=null;
  if(eventOverlay?.url&&eventOverlay?.coefficients&&eventOverlay?.width&&eventOverlay?.height){
    const AffineOverlay=createAffineOverlayClass();
    affineOverlay=new AffineOverlay({
      map,
      url:eventOverlay.url,
      width:eventOverlay.width,
      height:eventOverlay.height,
      coefficients:eventOverlay.coefficients,
      opacity:eventOverlay.opacity??.58
    });
  }

  const summary=document.querySelector("#fieldNavigationSummary");
  const warnings=document.querySelector("#fieldNavigationWarnings");
  const stepsHost=document.querySelector("#fieldNavigationSteps");

  const clearRoute=()=>{
    for(const polyline of routePolylines){
      try{polyline.setMap(null);}catch{}
    }
    routePolylines=[];
  };

  const fitOverview=()=>{
    if(latestRoute?.viewport){
      try{map.fitBounds(latestRoute.viewport,{top:60,right:40,bottom:60,left:40});return;}catch{}
    }
    const bounds=new google.maps.LatLngBounds();
    bounds.extend(destinationPoint);
    if(currentLocation)bounds.extend(currentLocation);
    map.fitBounds(bounds,{top:60,right:40,bottom:60,left:40});
  };

  const renderWarnings=route=>{
    const routeWarnings=route?.warnings||[];
    warnings.innerHTML=routeWarnings.length
      ?`<div class="notice field-navigation-warning">${routeWarnings.map(item=>`<div>${esc(item)}</div>`).join("")}</div>`
      :"";
  };

  const computeRoute=async(location,{fit=true,force=false}={})=>{
    const origin=normalizeLocation(location);
    if(!origin)return;
    const now=Date.now();
    if(!force&&lastRouteOrigin&&now-lastRouteAt<20000&&metersBetween(lastRouteOrigin,origin)<35)return;

    summary.textContent="Calculating route…";
    const recalc=document.querySelector("#fieldNavigationRecalculate");
    if(recalc){recalc.disabled=true;recalc.textContent="Routing…";}

    try{
      const request={
        origin,
        destination:destinationPoint,
        travelMode:mode,
        units:"IMPERIAL",
        fields:["path","legs","distanceMeters","durationMillis","localizedValues","warnings","viewport"]
      };
      const {routes}=await Route.computeRoutes(request);
      if(!routes?.length)throw new Error("Google did not return a route between the unit and this call.");

      latestRoute=routes[0];
      lastRouteOrigin={...origin};
      lastRouteAt=Date.now();
      clearRoute();
      routePolylines=latestRoute.createPolylines({
        polylineOptions:{strokeWeight:6,strokeOpacity:.92,zIndex:40}
      })||[];
      routePolylines.forEach(polyline=>polyline.setMap(map));

      const distance=latestRoute.localizedValues?.distance||formatDistance(latestRoute.distanceMeters);
      const duration=latestRoute.localizedValues?.duration||formatDuration(latestRoute.durationMillis);
      summary.innerHTML=`<strong>${esc(unitName)} → ${esc(incidentNumber)}</strong><span>${esc([distance,duration,mode.charAt(0)+mode.slice(1).toLowerCase()].filter(Boolean).join(" · "))}</span>`;
      renderWarnings(latestRoute);
      stepsHost.innerHTML=routeStepHtml(latestRoute);
      if(fit)fitOverview();
    }catch(error){
      console.error("CommCenter Google route failed",error);
      summary.innerHTML=`<span class="destructive-error">${esc(error.message||"Route calculation failed.")}</span>`;
      stepsHost.innerHTML="";
    }finally{
      if(recalc){recalc.disabled=false;recalc.textContent="Recalculate";}
    }
  };

  const updateLocation=location=>{
    if(destroyed)return;
    const point=normalizeLocation(location);
    if(!point)return;
    currentLocation=point;
    const accuracy=Number(location?.accuracy_m??location?.accuracy);

    if(!unitCircle){
      unitCircle=new google.maps.Circle({
        map,
        center:point,
        radius:6,
        strokeColor:"#1d4ed8",
        strokeOpacity:1,
        strokeWeight:3,
        fillColor:"#3b82f6",
        fillOpacity:.98,
        zIndex:70
      });
    }else unitCircle.setCenter(point);

    if(Number.isFinite(accuracy)&&accuracy>0){
      if(!accuracyCircle){
        accuracyCircle=new google.maps.Circle({
          map,
          center:point,
          radius:accuracy,
          strokeColor:"#2563eb",
          strokeOpacity:.35,
          strokeWeight:1,
          fillColor:"#60a5fa",
          fillOpacity:.09,
          zIndex:15
        });
      }else{
        accuracyCircle.setCenter(point);
        accuracyCircle.setRadius(accuracy);
      }
    }

    if(follow)map.panTo(point);

    if(rerouteTimer)clearTimeout(rerouteTimer);
    rerouteTimer=setTimeout(()=>{
      if(!destroyed)computeRoute(point,{fit:false,force:false});
    },500);
  };

  document.querySelector("#fieldNavigationMode")?.addEventListener("change",event=>{
    mode=String(event.target.value||"WALKING").toUpperCase();
    if(currentLocation)computeRoute(currentLocation,{fit:true,force:true});
  });

  document.querySelector("#fieldNavigationFollow")?.addEventListener("click",event=>{
    follow=!follow;
    event.currentTarget.textContent=`Follow Me: ${follow?"On":"Off"}`;
    event.currentTarget.classList.toggle("active",follow);
    if(follow&&currentLocation)map.panTo(currentLocation);
  });

  document.querySelector("#fieldNavigationOverview")?.addEventListener("click",()=>fitOverview());
  document.querySelector("#fieldNavigationRecalculate")?.addEventListener("click",async()=>{
    let location=currentLocation;
    if(getFreshLocation){
      try{location=await getFreshLocation()||location;}catch{}
    }
    if(location){updateLocation(location);await computeRoute(location,{fit:true,force:true});}
  });

  document.querySelector("#fieldNavigationOverlayToggle")?.addEventListener("click",event=>{
    if(!affineOverlay)return;
    overlayVisible=!overlayVisible;
    affineOverlay.setOpacity(overlayVisible?(eventOverlay.opacity??.58):0);
    event.currentTarget.textContent=`Event Overlay: ${overlayVisible?"On":"Off"}`;
  });

  const destroy=()=>{
    if(destroyed)return;
    destroyed=true;
    if(rerouteTimer)clearTimeout(rerouteTimer);
    if(localWatchId!=null&&navigator.geolocation){
      try{navigator.geolocation.clearWatch(localWatchId);}catch{}
      localWatchId=null;
    }
    clearRoute();
    try{callCircle.setMap(null);}catch{}
    try{unitCircle?.setMap(null);}catch{}
    try{accuracyCircle?.setMap(null);}catch{}
    try{affineOverlay?.setMap(null);}catch{}
    if(onClose)onClose();
  };

  document.querySelector("#fieldNavigationClose")?.addEventListener("click",()=>destroy());

  if(watchDeviceLocation&&navigator.geolocation&&window.isSecureContext){
    localWatchId=navigator.geolocation.watchPosition(position=>{
      if(destroyed)return;
      const coords=position.coords;
      const location={
        latitude:Number(coords.latitude),
        longitude:Number(coords.longitude),
        accuracy_m:Number.isFinite(coords.accuracy)?Number(coords.accuracy):null,
        altitude_m:Number.isFinite(coords.altitude)?Number(coords.altitude):null,
        heading_deg:Number.isFinite(coords.heading)?Number(coords.heading):null,
        speed_mps:Number.isFinite(coords.speed)?Number(coords.speed):null,
        client_time:new Date(position.timestamp||Date.now()).toISOString(),
        source:"navigation-local"
      };
      if(onLocalLocation)onLocalLocation(location);
      updateLocation(location);
    },error=>{
      console.warn("Local navigation GPS watch failed",error);
    },{
      enableHighAccuracy:true,
      maximumAge:3000,
      timeout:15000
    });
  }

  if(currentLocation){
    updateLocation(initialLocation);
    computeRoute(currentLocation,{fit:true,force:true});
  }else if(getFreshLocation){
    summary.textContent="Getting your location…";
    (async()=>{
      try{
        const location=await getFreshLocation();
        if(destroyed)return;
        if(location){updateLocation(location);computeRoute(location,{fit:true,force:true});}
        else throw new Error("Current device location is unavailable.");
      }catch(error){
        if(!destroyed)summary.innerHTML=`<span class="destructive-error">${esc(error.message||"Current location is unavailable.")}</span>`;
      }
    })();
  }

  return {map,updateLocation,computeRoute,fitOverview,destroy};
}
