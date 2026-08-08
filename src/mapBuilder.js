import L from "leaflet";
import { supabase } from "./supabase.js";
import { renderFirstPdfPage } from "./pdfMap.js";
import { fitAffine, pixelToGeo, geoToPixel, leafletToPixel, pixelToLeaflet } from "./georef.js";

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]));

function parseCsv(text){
  const lines=text.replace(/\r/g,"").split("\n").filter(Boolean);
  if(!lines.length)return[];
  const headers=lines[0].split(",").map(x=>x.trim().toLowerCase());
  return lines.slice(1).map(line=>{
    const vals=line.split(",").map(x=>x.trim().replace(/^"|"$/g,""));
    return Object.fromEntries(headers.map((h,i)=>[h,vals[i]]));
  });
}

async function fileToRows(file){
  const text=await file.text();
  if(file.name.toLowerCase().endsWith(".json")){
    const rows=JSON.parse(text);
    if(!Array.isArray(rows))throw new Error("JSON must be an array.");
    return rows;
  }
  return parseCsv(text);
}

async function signedMapUrl(path){
  if(!path)return null;
  const {data,error}=await supabase.storage.from("event-assets").createSignedUrl(path,3600);
  if(error)throw error;
  return data.signedUrl;
}

export async function renderMapBuilder(app,eventId,onBack){
  let map=null, overlay=null, imageMeta=null, points=[], pois=[], coeff=null, clickMode=null, w3wLayer=L.layerGroup();
  const event=(await supabase.from("events").select("id,name,event_code").eq("id",eventId).single()).data;

  app.innerHTML=`<div class="shell">
    <div class="topbar">
      <div class="brand">CommCenter Pro<small>${esc(event?.name||"Event")} · Map Builder</small></div>
      <div class="nav"><button class="btn secondary" id="backBtn">Back</button></div>
    </div>
    <div class="builder-layout">
      <div class="builder-map-wrap"><div id="builderMap"></div></div>
      <aside class="builder-side">
        <div class="stack">
          <div class="card step" id="stepUpload">
            <h3>1. Upload PDF map</h3>
            <p class="small muted">The first PDF page is rendered in your browser to a high-resolution WebP, then both files are stored in Supabase Storage.</p>
            <input id="pdfFile" type="file" accept="application/pdf">
            <button class="btn block" id="uploadPdf">Upload & Render PDF</button>
            <div id="uploadStatus" class="small muted"></div>
          </div>

          <div class="card step" id="stepGeo">
            <h3>2. Georeference</h3>
            <p class="small muted">Add at least 3 control points. More well-distributed points are better.</p>
            <button class="btn block" id="addControl">Click Map to Add Control Point</button>
            <div id="pendingControl"></div>
            <div id="controlList"></div>
            <button class="btn secondary block" id="calculate">Calculate Georeference</button>
            <div id="geoMetrics"></div>
          </div>

          <div class="card step" id="stepW3W">
            <h3>3. W3W library</h3>
            <p class="small muted">Import exact W3W square bounds as JSON or CSV with columns: words,south,north,west,east.</p>
            <input id="w3wFile" type="file" accept=".json,.csv,application/json,text/csv">
            <button class="btn block" id="importW3W">Import W3W Squares</button>
            <div class="progress"><div id="w3wProgress"></div></div>
            <div id="w3wStatus" class="small muted"></div>
            <button class="btn secondary block" id="showSquares">Show W3W Squares in View</button>
            <button class="btn secondary block" id="publishW3W">Publish Offline W3W Library</button>
          </div>

          <div class="card step" id="stepPoi">
            <h3>4. Points of Interest</h3>
            <p class="small muted">Click the map, give the point a common name, and CommCenter Pro links it to the W3W square covering that point.</p>
            <button class="btn block" id="addPoi">Click Map to Add POI</button>
            <div id="pendingPoi"></div>
            <div id="poiList"></div>
          </div>

          <div class="card step" id="stepPublish">
            <h3>5. Publish map</h3>
            <button class="btn good block" id="publishMap">Publish Event Map</button>
            <div id="publishStatus" class="small muted"></div>
          </div>
        </div>
      </aside>
    </div>
  </div>`;

  document.querySelector("#backBtn").onclick=()=>{if(map)map.remove();onBack();};

  async function loadAll(){
    const {data:m}=await supabase.from("event_maps").select("*").eq("event_id",eventId).maybeSingle();
    imageMeta=m||null;
    coeff=m?.georef_coefficients||null;
    const [{data:c},{data:p}]=await Promise.all([
      supabase.from("map_control_points").select("*").eq("event_id",eventId).order("created_at"),
      supabase.from("event_pois").select("*,poi_aliases(alias)").eq("event_id",eventId).eq("active",true).order("name")
    ]);
    points=c||[];pois=p||[];
    await setupMap();
    renderControlList();
    renderPoiList();
    updateStepState();
    if(coeff)renderSavedMetrics();
  }

  async function setupMap(){
    if(map){map.remove();map=null;}
    map=L.map("builderMap",{crs:L.CRS.Simple,minZoom:-4,maxZoom:5,zoomSnap:.25,attributionControl:false});
    w3wLayer=L.layerGroup().addTo(map);

    if(!imageMeta?.rendered_image_path){
      map.setView([0,0],0);
      return;
    }

    const url=await signedMapUrl(imageMeta.rendered_image_path);
    const bounds=[[0,0],[imageMeta.image_height,imageMeta.image_width]];
    overlay=L.imageOverlay(url,bounds).addTo(map);
    map.fitBounds(bounds);

    for(const cp of points){
      L.circleMarker(pixelToLeaflet(cp.map_x,cp.map_y,imageMeta.image_height),{radius:6})
        .addTo(map).bindTooltip(`CP: ${cp.label}`,{permanent:false});
    }
    for(const p of pois){
      L.marker(pixelToLeaflet(p.map_x,p.map_y,imageMeta.image_height))
        .addTo(map).bindTooltip(p.name);
    }

    map.on("click",async e=>{
      if(!imageMeta)return;
      const px=leafletToPixel(e.latlng,imageMeta.image_height);
      if(clickMode==="control"){
        clickMode=null;
        showControlForm(px);
      }else if(clickMode==="poi"){
        clickMode=null;
        await showPoiForm(px);
      }
    });
  }

  document.querySelector("#uploadPdf").onclick=async()=>{
    const file=document.querySelector("#pdfFile").files[0];
    if(!file)return alert("Choose a PDF first.");
    const status=document.querySelector("#uploadStatus");
    try{
      status.textContent="Rendering PDF in browser…";
      const rendered=await renderFirstPdfPage(file,5000);

      const sourcePath=`${eventId}/map/source.pdf`;
      const imagePath=`${eventId}/map/map.webp`;

      status.textContent="Uploading original PDF…";
      let result=await supabase.storage.from("event-assets").upload(sourcePath,file,{upsert:true,contentType:"application/pdf"});
      if(result.error)throw result.error;

      status.textContent="Uploading rendered map…";
      result=await supabase.storage.from("event-assets").upload(imagePath,rendered.blob,{upsert:true,contentType:"image/webp"});
      if(result.error)throw result.error;

      const {error}=await supabase.from("event_maps").upsert({
        event_id:eventId,
        source_pdf_path:sourcePath,
        rendered_image_path:imagePath,
        image_width:rendered.width,
        image_height:rendered.height,
        status:"draft",
        updated_at:new Date().toISOString()
      },{onConflict:"event_id"});
      if(error)throw error;

      status.textContent=`Uploaded. Rendered ${rendered.width} × ${rendered.height}px.`;
      await loadAll();
    }catch(err){
      status.textContent=`Error: ${err.message}`;
    }
  };

  document.querySelector("#addControl").onclick=()=>{
    if(!imageMeta)return alert("Upload a map first.");
    clickMode="control";
    document.querySelector("#pendingControl").innerHTML=`<div class="notice">Click the exact control point on the map.</div>`;
  };

  function showControlForm(px){
    document.querySelector("#pendingControl").innerHTML=`<div class="card stack" style="margin-top:8px">
      <strong>New control point</strong>
      <div class="small mono">x=${px.x.toFixed(2)} y=${px.y.toFixed(2)}</div>
      <div><label>Name / label</label><input id="cpLabel" placeholder="Gate N1"></div>
      <div><label>Latitude</label><input id="cpLat" inputmode="decimal" placeholder="43.9656552"></div>
      <div><label>Longitude</label><input id="cpLon" inputmode="decimal" placeholder="-88.5977022"></div>
      <button class="btn" id="saveCp">Save Control Point</button>
    </div>`;
    document.querySelector("#saveCp").onclick=async()=>{
      const row={
        event_id:eventId,label:document.querySelector("#cpLabel").value.trim(),
        map_x:px.x,map_y:px.y,
        latitude:Number(document.querySelector("#cpLat").value),
        longitude:Number(document.querySelector("#cpLon").value)
      };
      if(!row.label||!Number.isFinite(row.latitude)||!Number.isFinite(row.longitude))return alert("Complete all control point fields.");
      const {error}=await supabase.from("map_control_points").insert(row);
      if(error)return alert(error.message);
      document.querySelector("#pendingControl").innerHTML="";
      await loadAll();
    };
  }

  function renderControlList(residualMap={}){
    document.querySelector("#controlList").innerHTML=points.map(p=>`<div class="cp-row">
      <div class="row"><strong>${esc(p.label)}</strong><button class="btn secondary" data-delcp="${p.id}">Delete</button></div>
      <div class="small mono">${Number(p.latitude).toFixed(7)}, ${Number(p.longitude).toFixed(7)}</div>
      <div class="small muted">pixel ${Number(p.map_x).toFixed(1)}, ${Number(p.map_y).toFixed(1)}
      ${residualMap[p.id]!=null?` · error ${residualMap[p.id].toFixed(2)} m`:""}</div>
    </div>`).join("")||`<div class="small muted">No control points yet.</div>`;
    document.querySelectorAll("[data-delcp]").forEach(b=>b.onclick=async()=>{
      await supabase.from("map_control_points").delete().eq("id",b.dataset.delcp);
      await loadAll();
    });
  }

  document.querySelector("#calculate").onclick=async()=>{
    try{
      const result=fitAffine(points);
      coeff=result.coefficients;
      const {error}=await supabase.from("event_maps").update({
        georef_method:"affine",
        georef_coefficients:result.coefficients,
        georef_rmse_m:result.rmse,
        georef_max_error_m:result.max,
        status:"calibrated",
        updated_at:new Date().toISOString()
      }).eq("event_id",eventId);
      if(error)throw error;

      for(const r of result.residuals){
        await supabase.from("map_control_points").update({residual_m:r.meters}).eq("id",r.id);
      }
      const residualMap=Object.fromEntries(result.residuals.map(r=>[r.id,r.meters]));
      renderControlList(residualMap);
      renderMetrics(result.rmse,result.max);
      updateStepState();
    }catch(err){alert(err.message);}
  };

  function renderMetrics(rmse,max){
    document.querySelector("#geoMetrics").innerHTML=`<div class="grid2" style="margin-top:10px">
      <div><div class="metric">${rmse.toFixed(2)} m</div><div class="small muted">RMSE</div></div>
      <div><div class="metric">${max.toFixed(2)} m</div><div class="small muted">Maximum</div></div>
    </div>`;
  }
  function renderSavedMetrics(){
    renderMetrics(Number(imageMeta.georef_rmse_m||0),Number(imageMeta.georef_max_error_m||0));
  }

  document.querySelector("#importW3W").onclick=async()=>{
    const file=document.querySelector("#w3wFile").files[0];
    if(!file)return alert("Choose a JSON or CSV W3W file first.");
    const status=document.querySelector("#w3wStatus"),bar=document.querySelector("#w3wProgress");
    try{
      let rows=await fileToRows(file);
      rows=rows.map(r=>({
        event_id:eventId,
        words:String(r.words||"").replace(/^\/{3}/,"").trim(),
        south:Number(r.south),north:Number(r.north),west:Number(r.west),east:Number(r.east),
        center_lat:(Number(r.south)+Number(r.north))/2,
        center_lon:(Number(r.west)+Number(r.east))/2
      })).filter(r=>r.words&&[r.south,r.north,r.west,r.east].every(Number.isFinite));
      if(!rows.length)throw new Error("No valid W3W rows found.");

      const chunk=500;
      for(let i=0;i<rows.length;i+=chunk){
        const {error}=await supabase.from("event_w3w_squares").upsert(rows.slice(i,i+chunk),{onConflict:"event_id,words"});
        if(error)throw error;
        bar.style.width=`${Math.min(100,((i+chunk)/rows.length)*100)}%`;
        status.textContent=`Imported ${Math.min(i+chunk,rows.length).toLocaleString()} / ${rows.length.toLocaleString()}`;
      }
      updateStepState();
    }catch(err){status.textContent=`Error: ${err.message}`;}
  };

  document.querySelector("#showSquares").onclick=async()=>{
    if(!map||!coeff)return alert("Calibrate the map first.");
    w3wLayer.clearLayers();
    const b=map.getBounds();
    const corners=[
      leafletToPixel(b.getSouthWest(),imageMeta.image_height),
      leafletToPixel(b.getNorthEast(),imageMeta.image_height)
    ];
    const g1=pixelToGeo(corners[0].x,corners[0].y,coeff);
    const g2=pixelToGeo(corners[1].x,corners[1].y,coeff);
    const south=Math.min(g1.lat,g2.lat),north=Math.max(g1.lat,g2.lat),west=Math.min(g1.lon,g2.lon),east=Math.max(g1.lon,g2.lon);
    const {data,error}=await supabase.rpc("w3w_squares_in_bounds",{p_event_id:eventId,p_south:south,p_north:north,p_west:west,p_east:east,p_limit:2500});
    if(error)return alert(error.message);
    for(const s of data||[]){
      const geoCorners=[[s.south,s.west],[s.south,s.east],[s.north,s.east],[s.north,s.west]];
      const pts=geoCorners.map(([lat,lon])=>{
        const px=geoToPixel(lat,lon,coeff);
        return pixelToLeaflet(px.x,px.y,imageMeta.image_height);
      });
      L.polygon(pts,{weight:1,fillOpacity:0.05}).addTo(w3wLayer).bindTooltip(`///${s.words}`);
    }
    document.querySelector("#w3wStatus").textContent=`Showing ${(data||[]).length.toLocaleString()} squares in current view (capped at 2,500).`;
  };

  document.querySelector("#publishW3W").onclick=async()=>{
    const status=document.querySelector("#w3wStatus");
    try{
      status.textContent="Building offline JSON…";
      let all=[],from=0,page=1000;
      while(true){
        const {data,error}=await supabase.from("event_w3w_squares")
          .select("words,south,north,west,east")
          .eq("event_id",eventId).range(from,from+page-1);
        if(error)throw error;
        all.push(...data);
        if(data.length<page)break;
        from+=page;
        status.textContent=`Loaded ${all.length.toLocaleString()} squares…`;
      }
      const path=`${eventId}/offline/w3w.json`;
      const blob=new Blob([JSON.stringify(all)],{type:"application/json"});
      const {error:upErr}=await supabase.storage.from("event-assets").upload(path,blob,{upsert:true,contentType:"application/json"});
      if(upErr)throw upErr;
      const {error}=await supabase.from("event_maps").update({offline_w3w_path:path,updated_at:new Date().toISOString()}).eq("event_id",eventId);
      if(error)throw error;
      status.textContent=`Offline library published: ${all.length.toLocaleString()} squares.`;
    }catch(err){status.textContent=`Error: ${err.message}`;}
  };

  document.querySelector("#addPoi").onclick=()=>{
    if(!coeff)return alert("Calculate the georeference first.");
    clickMode="poi";
    document.querySelector("#pendingPoi").innerHTML=`<div class="notice">Click the POI on the map.</div>`;
  };

  async function showPoiForm(px){
    const geo=pixelToGeo(px.x,px.y,coeff);
    const {data:words}=await supabase.rpc("w3w_for_coordinate",{p_event_id:eventId,p_lat:geo.lat,p_lon:geo.lon});
    document.querySelector("#pendingPoi").innerHTML=`<div class="card stack" style="margin-top:8px">
      <strong>New POI</strong>
      <div><label>Common name</label><input id="poiName" placeholder="Main Medical"></div>
      <div><label>Category</label><select id="poiCategory">
        <option>Medical</option><option>Command</option><option>Gate</option><option>Stage</option>
        <option>Security</option><option>Parking</option><option>Production</option><option>Facilities</option>
        <option>Transportation</option><option>Guest Services</option><option>Other</option>
      </select></div>
      <div><label>Aliases (comma separated)</label><input id="poiAliases" placeholder="Main Med, Med Tent"></div>
      <div><label>Notes</label><textarea id="poiNotes" rows="2"></textarea></div>
      <div class="small mono">${geo.lat.toFixed(7)}, ${geo.lon.toFixed(7)}</div>
      <div class="${words?"notice ok":"notice"}">${words?`W3W: ///${esc(words)}`:"No W3W square is loaded for this point yet."}</div>
      <button class="btn" id="savePoi">Save POI</button>
    </div>`;
    document.querySelector("#savePoi").onclick=async()=>{
      const name=document.querySelector("#poiName").value.trim();
      if(!name)return alert("Enter a POI name.");
      const square=words ? (await supabase.from("event_w3w_squares").select("id,words").eq("event_id",eventId).eq("words",words).maybeSingle()).data : null;
      const {data:poi,error}=await supabase.from("event_pois").insert({
        event_id:eventId,name,category:document.querySelector("#poiCategory").value,
        latitude:geo.lat,longitude:geo.lon,map_x:px.x,map_y:px.y,
        w3w_square_id:square?.id||null,w3w:words||null,notes:document.querySelector("#poiNotes").value.trim()
      }).select().single();
      if(error)return alert(error.message);
      const aliases=document.querySelector("#poiAliases").value.split(",").map(x=>x.trim()).filter(Boolean);
      if(aliases.length){
        const {error:aerr}=await supabase.from("poi_aliases").insert(aliases.map(alias=>({poi_id:poi.id,alias})));
        if(aerr)return alert(aerr.message);
      }
      document.querySelector("#pendingPoi").innerHTML="";
      await loadAll();
    };
  }

  function renderPoiList(){
    document.querySelector("#poiList").innerHTML=pois.map(p=>`<div class="poi-row">
      <div class="row"><strong>${esc(p.name)}</strong><button class="btn secondary" data-delpoi="${p.id}">Delete</button></div>
      <div class="small">${esc(p.category||"Other")}${p.w3w?` · ///${esc(p.w3w)}`:""}</div>
      <div class="small muted">${(p.poi_aliases||[]).map(a=>esc(a.alias)).join(", ")}</div>
    </div>`).join("")||`<div class="small muted">No POIs yet.</div>`;
    document.querySelectorAll("[data-delpoi]").forEach(b=>b.onclick=async()=>{
      await supabase.from("event_pois").update({active:false}).eq("id",b.dataset.delpoi);
      await loadAll();
    });
  }

  document.querySelector("#publishMap").onclick=async()=>{
    if(!imageMeta?.rendered_image_path)return alert("Upload a map first.");
    if(!coeff)return alert("Calibrate the map first.");
    const {error}=await supabase.from("event_maps").update({status:"published",published_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("event_id",eventId);
    document.querySelector("#publishStatus").textContent=error?error.message:"Published. Dispatch can now use this event map.";
    updateStepState();
  };

  async function updateStepState(){
    const {count}=await supabase.from("event_w3w_squares").select("*",{count:"exact",head:true}).eq("event_id",eventId);
    document.querySelector("#stepUpload").classList.toggle("complete",!!imageMeta?.rendered_image_path);
    document.querySelector("#stepGeo").classList.toggle("complete",!!coeff);
    document.querySelector("#stepW3W").classList.toggle("complete",(count||0)>0);
    document.querySelector("#stepPoi").classList.toggle("complete",pois.length>0);
    document.querySelector("#stepPublish").classList.toggle("complete",imageMeta?.status==="published");
    if((count||0)>0)document.querySelector("#w3wStatus").textContent=`${count.toLocaleString()} W3W squares loaded.`;
  }

  await loadAll();
}
