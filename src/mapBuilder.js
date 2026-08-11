import L from "leaflet";
import { supabase } from "./supabase.js";
import { createFirstPdfPagePreview, renderFirstPdfCrop, normalizePdfCrop } from "./pdfMap.js";
import { fitAffine, pixelToGeo, geoToPixel, leafletToPixel, pixelToLeaflet } from "./georef.js";

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]));

async function signedMapUrl(path){if(!path)return null;const {data,error}=await supabase.storage.from("event-assets").createSignedUrl(path,3600);if(error)throw error;return data.signedUrl;}

export async function renderMapBuilder(app,eventId,onBack){
  let map=null, layerGroup=null, clickMode=null;
  let event=null,layers=[],activeLayer=null,points=[],pois=[],zones=[],accessPoints=[],accessNodes=[],coeff=null;

  app.innerHTML=`<div class="shell"><div class="topbar"><div class="brand">CommCenter Pro<small id="builderSubtitle">Venue Map Builder</small></div><div class="nav"><button class="btn secondary" id="backBtn">Back</button></div></div>
  <div class="builder-layout stadium-builder"><div class="builder-map-wrap"><div id="builderMap"></div></div><aside class="builder-side"><div id="builderControls" class="stack"></div></aside></div></div>`;
  document.querySelector("#backBtn").onclick=()=>{if(map)map.remove();onBack();};

  async function loadAll(preferredLayerId=null){
    const [eventRes,layersRes,poisRes,zonesRes,apsRes,nodesRes]=await Promise.all([
      supabase.from("events").select("*").eq("id",eventId).single(),
      supabase.from("event_map_layers").select("*").eq("event_id",eventId).eq("active",true).order("sort_order"),
      supabase.from("event_pois").select("*,poi_aliases(alias)").eq("event_id",eventId).eq("active",true).order("name"),
      supabase.from("event_zones").select("*").eq("event_id",eventId).eq("active",true).order("sort_order"),
      supabase.from("venue_access_points").select("*").eq("event_id",eventId).eq("active",true).order("name"),
      supabase.from("venue_access_point_nodes").select("*")
    ]);
    for(const r of [eventRes,layersRes,poisRes,zonesRes,apsRes,nodesRes])if(r.error)throw r.error;
    event=eventRes.data;layers=layersRes.data||[];pois=poisRes.data||[];zones=zonesRes.data||[];accessPoints=apsRes.data||[];
    const apIds=new Set(accessPoints.map(x=>x.id));accessNodes=(nodesRes.data||[]).filter(n=>apIds.has(n.access_point_id));
    activeLayer=layers.find(l=>l.id===(preferredLayerId||activeLayer?.id))||layers.find(l=>l.is_default)||layers[0]||null;
    if(activeLayer){const cp=await supabase.from("map_control_points").select("*").eq("event_id",eventId).eq("map_layer_id",activeLayer.id).order("created_at");if(cp.error)throw cp.error;points=cp.data||[];coeff=activeLayer.georef_coefficients||null;}else{points=[];coeff=null;}
    document.querySelector("#builderSubtitle").textContent=`${event?.name||"Event"} · ${activeLayer?.name||"No map layer"}`;
    renderControls(); await setupMap();
  }

  function layerOptionHtml(){return layers.map(l=>`<option value="${l.id}" ${l.id===activeLayer?.id?"selected":""}>${esc(l.name)}${l.level_code?` · ${esc(l.level_code)}`:""}${l.status==="published"?" ✓":""}</option>`).join("");}
  function currentZones(){return zones.filter(z=>z.map_layer_id===activeLayer?.id);}
  function currentPois(){return pois.filter(p=>p.map_layer_id===activeLayer?.id);}
  function poiAliasList(p){return (p?.poi_aliases||[]).map(a=>a.alias).filter(Boolean);}
  function layerCrop(layer=activeLayer){
    return normalizePdfCrop({
      x:layer?.pdf_crop_x??0,
      y:layer?.pdf_crop_y??0,
      width:layer?.pdf_crop_width??1,
      height:layer?.pdf_crop_height??1
    });
  }

  function renderControls(){
    const controls=document.querySelector("#builderControls");
    controls.innerHTML=`
      <div class="card"><div class="row"><div><div class="section-title">Venue</div><h3 style="margin-bottom:4px">Map Layers</h3></div><span class="badge">${esc(event?.venue_type||"outdoor")}</span></div>
        <div><label>Venue type</label><select id="venueType"><option value="outdoor" ${event?.venue_type==="outdoor"?"selected":""}>Outdoor / Campus</option><option value="multi_level" ${event?.venue_type==="multi_level"?"selected":""}>Multi-Level Venue</option><option value="hybrid" ${event?.venue_type==="hybrid"?"selected":""}>Hybrid</option></select></div>
        <div><label>Active map layer</label><select id="layerSelect"><option value="">-- No layers --</option>${layerOptionHtml()}</select></div>
        <button class="btn secondary block" id="newLayer">+ Add Map Layer / Level</button><div id="newLayerForm"></div>
      </div>
      ${activeLayer?`
      <div class="card step ${activeLayer.rendered_image_path?"complete":""}">
        <h3>1. ${esc(activeLayer.name)} PDF</h3>
        <p class="small muted">Upload the map for this level only. You can crop page margins, legends, title blocks, or unused areas before the operational map is rendered.</p>
        <input id="pdfFile" type="file" accept="application/pdf">
        <label class="crop-option"><input type="checkbox" id="cropPdfBeforeSave" checked> Crop PDF before saving</label>
        <button class="btn block" id="uploadPdf">Upload PDF</button>
        ${activeLayer.source_pdf_path?`<button class="btn secondary block" id="recropPdf">Crop Current PDF</button>`:""}
        ${activeLayer.rendered_image_path?`<div class="small muted">Current crop: ${Math.round((activeLayer.pdf_crop_width??1)*100)}% × ${Math.round((activeLayer.pdf_crop_height??1)*100)}% of page</div>`:""}
        <div id="uploadStatus" class="small muted"></div>
      </div>
      <div class="card step ${coeff?"complete":""}"><h3>2. Georeference this level</h3><button class="btn block" id="addControl">Click Map to Add Control Point</button><div id="pendingControl"></div><div id="controlList">${controlHtml()}</div><button class="btn secondary block" id="calculate">Calculate Georeference</button><div id="geoMetrics">${metricHtml()}</div></div>
      <div class="card"><h3>3. Zones</h3><p class="small muted">Create operational areas for this map layer.</p><div id="zoneList">${zoneHtml()}</div><div class="grid2"><input id="zoneName" placeholder="Zone name"><input id="zoneShort" placeholder="Short name"></div><button class="btn secondary block" id="addZone">Add Zone to ${esc(activeLayer.name)}</button></div>
      <div class="card"><h3>4. POIs / Common Names</h3><button class="btn block" id="addPoi">Click Map to Add POI</button><div id="pendingPoi"></div><div id="poiList">${poiHtml()}</div></div>
      <div class="card"><h3>5. Vertical Access</h3><p class="small muted">Link access points across map layers.</p><button class="btn block" id="addAccess">Click Map to Add / Link Access Point</button><div id="pendingAccess"></div><div id="accessList">${accessHtml()}</div></div>
      <div class="card step ${activeLayer.status==="published"?"complete":""}"><h3>6. Publish Layer</h3><label><input type="checkbox" id="makeDefault" ${activeLayer.is_default?"checked":""}> Default map layer for this event</label><button class="btn good block" id="publishLayer">Publish ${esc(activeLayer.name)}</button><div id="publishStatus" class="small muted"></div></div>`:`<div class="notice">Create the map layers needed for this venue.</div>`}`;
    bindControls();
  }

  function controlHtml(){return points.map(p=>`<div class="cp-row"><div class="row"><strong>${esc(p.label)}</strong><button class="btn secondary" data-delcp="${p.id}">Delete</button></div><div class="small mono">${Number(p.latitude).toFixed(7)}, ${Number(p.longitude).toFixed(7)}</div><div class="small muted">${p.residual_m!=null?`error ${Number(p.residual_m).toFixed(2)} m`:"not calculated"}</div></div>`).join("")||`<div class="small muted">No control points on this layer.</div>`;}
  function metricHtml(){return coeff?`<div class="grid2"><div><div class="metric">${Number(activeLayer.georef_rmse_m||0).toFixed(2)} m</div><div class="small muted">RMSE</div></div><div><div class="metric">${Number(activeLayer.georef_max_error_m||0).toFixed(2)} m</div><div class="small muted">Max</div></div></div>`:"";}
  function poiMapIcon(){
    return L.divIcon({
      className:"cc-leaflet-div-icon",
      html:`<span class="cc-map-pin cc-poi-pin" aria-hidden="true"><span class="cc-map-pin-dot"></span></span>`,
      iconSize:[20,20],
    iconAnchor:[10,10],
    tooltipAnchor:[0,-10]
    });
  }

  function zoneHtml(){
    return currentZones().map(z=>`<div class="poi-row">
      <div class="row">
        <div>
          <strong>${esc(z.name)}</strong>
          ${z.short_name?`<span class="badge">${esc(z.short_name)}</span>`:""}
        </div>
        <div class="row" style="gap:6px">
          <button class="btn secondary compact" data-edit-zone="${z.id}">Edit</button>
          <button class="btn danger compact" data-delete-zone="${z.id}">Delete</button>
        </div>
      </div>
      <div class="small muted">${esc([z.category,z.notes].filter(Boolean).join(" · "))}</div>
    </div>`).join("")||`<div class="small muted">No zones on this level.</div>`;
  }
  function poiHtml(){
    return currentPois().map(p=>{
      const z=zones.find(x=>x.id===p.zone_id);
      const aliases=poiAliasList(p);
      return `<div class="poi-row">
        <div class="row">
          <div>
            <strong>${esc(p.name)}</strong>
            <span class="badge">${p.poi_scope==="venue_snapshot"?"Venue":"Event"}</span>
          </div>
          <div class="row" style="gap:6px">
            <button class="btn secondary compact" data-edit-poi="${p.id}">Edit</button>
            <button class="btn danger compact" data-delete-poi="${p.id}">Delete</button>
          </div>
        </div>
        <div class="small muted">${esc([p.category,z?.name].filter(Boolean).join(" · "))}</div>
        ${aliases.length?`<div class="small muted">Aliases: ${esc(aliases.join(", "))}</div>`:""}
      </div>`;
    }).join("")||`<div class="small muted">No POIs on this level.</div>`;
  }
  function accessHtml(){return accessPoints.map(ap=>{const linked=accessNodes.filter(n=>n.access_point_id===ap.id).map(n=>layers.find(l=>l.id===n.map_layer_id)?.short_name||layers.find(l=>l.id===n.map_layer_id)?.name).filter(Boolean);return `<div class="poi-row"><strong>${esc(ap.name)}</strong> <span class="badge">${esc(ap.access_type)}</span><br><span class="small muted">${esc(linked.join(" ↕ "))}</span></div>`;}).join("")||`<div class="small muted">No vertical access points yet.</div>`;}

  function bindControls(){
    document.querySelector("#venueType").onchange=async e=>{await supabase.from("events").update({venue_type:e.target.value}).eq("id",eventId);await loadAll();};
    document.querySelector("#layerSelect").onchange=e=>loadAll(e.target.value);
    document.querySelector("#newLayer").onclick=()=>{document.querySelector("#newLayerForm").innerHTML=`<div class="stack" style="margin-top:10px"><input id="layerName" placeholder="Map layer name"><div class="grid2"><input id="layerShort" placeholder="Short code"><select id="layerType"><option value="exterior">Exterior / Campus</option><option value="field">Field / Event Level</option><option value="concourse" selected>Concourse</option><option value="suite">Suites / Club</option><option value="deck">Deck</option><option value="back_of_house">Back of House</option><option value="parking">Parking</option><option value="other">Other</option></select></div><button class="btn" id="saveLayer">Create Layer</button></div>`;document.querySelector("#saveLayer").onclick=createLayer;};
    if(!activeLayer)return;
    document.querySelector("#uploadPdf").onclick=uploadPdf;
    document.querySelector("#recropPdf")?.addEventListener("click",recropCurrentPdf);
    document.querySelector("#addControl").onclick=()=>{if(!activeLayer.rendered_image_path)return alert("Upload this layer's PDF first.");clickMode="control";document.querySelector("#pendingControl").innerHTML=`<div class="notice">Click the exact known point on ${esc(activeLayer.name)}.</div>`;};
    document.querySelector("#calculate").onclick=calculateGeoref;
    document.querySelectorAll("[data-delcp]").forEach(b=>b.onclick=async()=>{await supabase.from("map_control_points").delete().eq("id",b.dataset.delcp);await loadAll(activeLayer.id);});
    document.querySelector("#addZone").onclick=addZone;
    document.querySelectorAll("[data-edit-zone]").forEach(b=>b.onclick=()=>showEditZoneForm(b.dataset.editZone));
    document.querySelectorAll("[data-delete-zone]").forEach(b=>b.onclick=()=>deleteZone(b.dataset.deleteZone));
    document.querySelector("#addPoi").onclick=()=>{if(!coeff)return alert("Georeference this layer first.");clickMode="poi";document.querySelector("#pendingPoi").innerHTML=`<div class="notice">Click the POI on ${esc(activeLayer.name)}.</div>`;};
    document.querySelectorAll("[data-edit-poi]").forEach(b=>b.onclick=()=>showEditPoiForm(b.dataset.editPoi));
    document.querySelectorAll("[data-delete-poi]").forEach(b=>b.onclick=()=>deletePoi(b.dataset.deletePoi));
    document.querySelector("#addAccess").onclick=()=>{if(!coeff)return alert("Georeference this layer first.");clickMode="access";document.querySelector("#pendingAccess").innerHTML=`<div class="notice">Click the access point on ${esc(activeLayer.name)}.</div>`;};
    document.querySelector("#publishLayer").onclick=publishLayer;
  }

  async function createLayer(){const name=document.querySelector("#layerName").value.trim();if(!name)return alert("Enter a layer name.");const {data,error}=await supabase.from("event_map_layers").insert({event_id:eventId,name,short_name:document.querySelector("#layerShort").value.trim()||null,level_code:document.querySelector("#layerShort").value.trim()||null,level_type:document.querySelector("#layerType").value,sort_order:(layers.length+1)*10,is_default:layers.length===0}).select().single();if(error)return alert(error.message);await loadAll(data.id);}
  function mappedLayerHasOperationalData(){
    return !!(
      coeff ||
      points.length ||
      currentPois().length ||
      accessNodes.some(n=>n.map_layer_id===activeLayer?.id)
    );
  }

  async function uploadPdf(){
    const file=document.querySelector("#pdfFile").files[0];
    if(!file)return alert("Choose a PDF.");

    if(activeLayer.rendered_image_path&&mappedLayerHasOperationalData()){
      return alert("This layer already has georeferencing, POIs, or mapped access points. To crop the existing map without breaking those coordinates, use “Crop Current PDF.” Replacing the source PDF of a configured layer is intentionally blocked.");
    }

    const st=document.querySelector("#uploadStatus");
    try{
      if(document.querySelector("#cropPdfBeforeSave")?.checked){
        st.textContent="Preparing crop preview…";
        await openPdfCropEditor(file,{
          sourceReplaced:true,
          initialCrop:{x:0,y:0,width:1,height:1},
          statusElement:st
        });
      }else{
        st.textContent="Rendering full PDF page…";
        await commitPdfMap(file,{
          sourceReplaced:true,
          crop:{x:0,y:0,width:1,height:1},
          statusElement:st
        });
      }
    }catch(error){
      st.textContent=error.message;
    }
  }

  async function recropCurrentPdf(){
    if(!activeLayer?.source_pdf_path)return alert("This layer does not have a source PDF.");
    const st=document.querySelector("#uploadStatus");

    try{
      st.textContent="Loading source PDF…";
      const url=await signedMapUrl(activeLayer.source_pdf_path);
      const response=await fetch(url);
      if(!response.ok)throw new Error(`Could not load source PDF (${response.status}).`);
      const blob=await response.blob();
      const file=new File([blob],`${activeLayer.name||"map"}.pdf`,{type:"application/pdf"});

      st.textContent="Preparing crop preview…";
      await openPdfCropEditor(file,{
        sourceReplaced:false,
        initialCrop:layerCrop(activeLayer),
        statusElement:st
      });
    }catch(error){
      st.textContent=error.message;
    }
  }

  async function openPdfCropEditor(file,{sourceReplaced,initialCrop,statusElement}){
    const preview=await createFirstPdfPagePreview(file,1400);
    const crop=normalizePdfCrop(initialCrop);
    let selection={...crop};
    let dragStart=null;
    let dragging=false;

    document.querySelector("#pdfCropBackdrop")?.remove();

    const backdrop=document.createElement("div");
    backdrop.id="pdfCropBackdrop";
    backdrop.className="pdf-crop-backdrop open";
    backdrop.innerHTML=`<div class="pdf-crop-modal" role="dialog" aria-modal="true" aria-labelledby="pdfCropTitle">
      <div class="pdf-crop-header">
        <div>
          <div class="section-title">Map Preparation</div>
          <h2 id="pdfCropTitle">Crop PDF Map</h2>
        </div>
        <button class="btn secondary compact" id="closePdfCrop" aria-label="Close crop editor">Close</button>
      </div>
      <div class="pdf-crop-help">
        Drag a rectangle around the part of the PDF you want to keep. Drag again to replace the selection.
        The original PDF is retained; only CommCenter's rendered operational map is cropped.
      </div>
      <div class="pdf-crop-stage">
        <div class="pdf-crop-canvas-wrap" id="pdfCropCanvasWrap">
          <div class="pdf-crop-selection" id="pdfCropSelection"></div>
        </div>
      </div>
      <div class="pdf-crop-footer">
        <div>
          <strong id="pdfCropSize"></strong>
          <div class="small muted">PDF page 1${preview.pageCount>1?` of ${preview.pageCount}`:""} · crop coordinates are saved relative to the original page.</div>
        </div>
        <div class="pdf-crop-actions">
          <button class="btn secondary" id="pdfCropFull">Use Full Page</button>
          <button class="btn secondary" id="pdfCropCancel">Cancel</button>
          <button class="btn good" id="pdfCropApply">Apply Crop & Save Map</button>
        </div>
      </div>
    </div>`;

    document.body.appendChild(backdrop);
    document.body.classList.add("pdf-crop-open");

    const wrap=backdrop.querySelector("#pdfCropCanvasWrap");
    preview.canvas.className="pdf-crop-canvas";
    wrap.prepend(preview.canvas);

    const selectionEl=backdrop.querySelector("#pdfCropSelection");
    const sizeEl=backdrop.querySelector("#pdfCropSize");
    const applyBtn=backdrop.querySelector("#pdfCropApply");

    const close=()=>{
      document.body.classList.remove("pdf-crop-open");
      backdrop.remove();
      preview.canvas.width=1;
      preview.canvas.height=1;
    };

    const updateSelection=()=>{
      const s=normalizePdfCrop(selection);
      selection=s;
      selectionEl.style.left=`${s.x*100}%`;
      selectionEl.style.top=`${s.y*100}%`;
      selectionEl.style.width=`${s.width*100}%`;
      selectionEl.style.height=`${s.height*100}%`;

      const estimatedWidth=Math.round(Math.min(6500,5000/s.width)*s.width);
      const estimatedHeight=Math.round(estimatedWidth*(preview.canvas.height/preview.canvas.width)*(s.height/s.width));
      sizeEl.textContent=`Keeping ${Math.round(s.width*100)}% × ${Math.round(s.height*100)}% of page · about ${estimatedWidth} × ${estimatedHeight}px`;
    };

    const pointerToNormalized=e=>{
      const rect=wrap.getBoundingClientRect();
      return {
        x:Math.max(0,Math.min(1,(e.clientX-rect.left)/rect.width)),
        y:Math.max(0,Math.min(1,(e.clientY-rect.top)/rect.height))
      };
    };

    wrap.addEventListener("pointerdown",e=>{
      if(e.button!==undefined&&e.button!==0)return;
      e.preventDefault();
      dragStart=pointerToNormalized(e);
      selection={x:dragStart.x,y:dragStart.y,width:0.001,height:0.001};
      dragging=true;
      try{wrap.setPointerCapture(e.pointerId);}catch{}
      updateSelection();
    });

    wrap.addEventListener("pointermove",e=>{
      if(!dragging||!dragStart)return;
      e.preventDefault();
      const p=pointerToNormalized(e);
      const x=Math.min(dragStart.x,p.x);
      const y=Math.min(dragStart.y,p.y);
      const width=Math.abs(p.x-dragStart.x);
      const height=Math.abs(p.y-dragStart.y);
      selection={
        x,
        y,
        width:Math.max(0.001,width),
        height:Math.max(0.001,height)
      };
      updateSelection();
    });

    const endDrag=e=>{
      if(!dragging)return;
      dragging=false;
      try{wrap.releasePointerCapture(e.pointerId);}catch{}
      if(selection.width<0.02||selection.height<0.02){
        selection={...crop};
        updateSelection();
      }
    };
    wrap.addEventListener("pointerup",endDrag);
    wrap.addEventListener("pointercancel",endDrag);

    backdrop.querySelector("#pdfCropFull").onclick=()=>{
      selection={x:0,y:0,width:1,height:1};
      updateSelection();
    };
    backdrop.querySelector("#closePdfCrop").onclick=close;
    backdrop.querySelector("#pdfCropCancel").onclick=()=>{
      statusElement.textContent="Crop cancelled.";
      close();
    };

    applyBtn.onclick=async()=>{
      applyBtn.disabled=true;
      applyBtn.textContent="Rendering & saving…";
      try{
        const chosen=normalizePdfCrop(selection);
        close();
        statusElement.textContent="Rendering cropped map…";
        await commitPdfMap(file,{
          sourceReplaced,
          crop:chosen,
          statusElement
        });
      }catch(error){
        statusElement.textContent=error.message;
      }
    };

    backdrop.addEventListener("click",e=>{
      if(e.target===backdrop){
        statusElement.textContent="Crop cancelled.";
        close();
      }
    });

    updateSelection();
  }

  async function commitPdfMap(file,{sourceReplaced,crop,statusElement}){
    const base=`${eventId}/layers/${activeLayer.id}`;
    const stamp=Date.now();
    let newSourcePath=null;
    let newImagePath=null;
    let committed=false;

    try{
      const rendered=await renderFirstPdfCrop(file,crop,5000);

      let sourcePath=activeLayer.source_pdf_path||null;
      if(sourceReplaced){
        statusElement.textContent="Uploading source PDF…";
        newSourcePath=`${base}/source-${stamp}.pdf`;
        const sourceUpload=await supabase.storage.from("event-assets").upload(
          newSourcePath,
          file,
          {upsert:false,contentType:"application/pdf"}
        );
        if(sourceUpload.error)throw sourceUpload.error;
        sourcePath=newSourcePath;
      }

      statusElement.textContent="Uploading cropped map…";
      newImagePath=`${base}/map-${stamp}.webp`;
      const imageUpload=await supabase.storage.from("event-assets").upload(
        newImagePath,
        rendered.blob,
        {upsert:false,contentType:"image/webp"}
      );
      if(imageUpload.error)throw imageUpload.error;

      statusElement.textContent="Updating map coordinates…";
      const {error}=await supabase.rpc("admin_apply_event_map_crop",{
        p_map_layer_id:activeLayer.id,
        p_source_pdf_path:sourcePath,
        p_rendered_image_path:newImagePath,
        p_image_width:rendered.width,
        p_image_height:rendered.height,
        p_crop_x:rendered.crop.x,
        p_crop_y:rendered.crop.y,
        p_crop_width:rendered.crop.width,
        p_crop_height:rendered.crop.height,
        p_source_replaced:!!sourceReplaced
      });
      if(error)throw error;

      committed=true;
      statusElement.textContent=`Map saved · ${rendered.width} × ${rendered.height}px`;
      await loadAll(activeLayer.id);
    }catch(error){
      if(!committed){
        const orphaned=[newImagePath,newSourcePath].filter(Boolean);
        if(orphaned.length){
          try{await supabase.storage.from("event-assets").remove(orphaned);}catch{}
        }
      }
      throw error;
    }
  }

  async function calculateGeoref(){try{const result=fitAffine(points);for(const r of result.residuals)await supabase.from("map_control_points").update({residual_m:r.meters}).eq("id",r.id);const {error}=await supabase.from("event_map_layers").update({georef_method:"affine",georef_coefficients:result.coefficients,georef_rmse_m:result.rmse,georef_max_error_m:result.max,status:"calibrated",updated_at:new Date().toISOString()}).eq("id",activeLayer.id);if(error)throw error;await loadAll(activeLayer.id);}catch(e){alert(e.message);}}
  async function addZone(){
    const name=document.querySelector("#zoneName").value.trim();
    if(!name)return alert("Enter a zone name.");
    const {error}=await supabase.from("event_zones").insert({
      event_id:eventId,
      map_layer_id:activeLayer.id,
      name,
      short_name:document.querySelector("#zoneShort").value.trim()||null
    });
    if(error)alert(error.message);
    else await loadAll(activeLayer.id);
  }

  function showEditZoneForm(zoneId){
    const z=zones.find(x=>x.id===zoneId);
    if(!z)return alert("Zone not found.");

    const sourceNotice=z.source_venue_zone_id
      ?`<div class="notice small">This zone came from the venue snapshot. Changes here apply only to this event copy; the saved Venue Library version is not modified.</div>`
      :"";

    document.querySelector("#zoneList").innerHTML=`<div class="card stack">
      <div class="row">
        <div>
          <div class="section-title">Edit Zone</div>
          <strong>${esc(z.name)}</strong>
        </div>
        ${z.short_name?`<span class="badge">${esc(z.short_name)}</span>`:""}
      </div>
      ${sourceNotice}
      <label>Name</label>
      <input id="editZoneName" value="${esc(z.name)}" placeholder="Zone name">
      <label>Short name</label>
      <input id="editZoneShort" value="${esc(z.short_name||"")}" placeholder="Short name">
      <label>Category</label>
      <input id="editZoneCategory" value="${esc(z.category||"")}" placeholder="Optional category">
      <label>Notes</label>
      <textarea id="editZoneNotes" placeholder="Optional notes">${esc(z.notes||"")}</textarea>
      <label>Sort order</label>
      <input id="editZoneSort" type="number" step="1" value="${Number.isFinite(Number(z.sort_order))?Number(z.sort_order):100}">
      <div class="grid2">
        <button class="btn" id="saveZoneChanges">Save Changes</button>
        <button class="btn secondary" id="cancelZoneEdit">Cancel</button>
      </div>
      <button class="btn danger block" id="deleteZoneFromEdit">Delete Zone</button>
    </div>`;

    document.querySelector("#saveZoneChanges").onclick=()=>saveZoneChanges(z);
    document.querySelector("#cancelZoneEdit").onclick=()=>renderControls();
    document.querySelector("#deleteZoneFromEdit").onclick=()=>deleteZone(z.id);
  }

  async function saveZoneChanges(z){
    const name=document.querySelector("#editZoneName").value.trim();
    if(!name)return alert("Enter a zone name.");

    const sortValue=Number(document.querySelector("#editZoneSort").value);
    if(!Number.isFinite(sortValue))return alert("Sort order must be a number.");

    const button=document.querySelector("#saveZoneChanges");
    button.disabled=true;
    button.textContent="Saving…";

    const {error}=await supabase.rpc("admin_update_event_zone",{
      p_zone_id:z.id,
      p_name:name,
      p_short_name:document.querySelector("#editZoneShort").value.trim()||null,
      p_category:document.querySelector("#editZoneCategory").value.trim()||null,
      p_notes:document.querySelector("#editZoneNotes").value.trim()||null,
      p_sort_order:Math.trunc(sortValue)
    });

    if(error){
      button.disabled=false;
      button.textContent="Save Changes";
      return alert(error.message);
    }

    await loadAll(activeLayer.id);
  }

  async function deleteZone(zoneId){
    const z=zones.find(x=>x.id===zoneId);
    if(!z)return alert("Zone not found.");

    const linkedPois=pois.filter(p=>p.zone_id===z.id).length;
    const detail=linkedPois
      ?`\n\n${linkedPois} active POI${linkedPois===1?" is":"s are"} assigned to this zone. ${linkedPois===1?"It":"They"} will remain on the map but become unzoned.`
      :"";

    if(!confirm(`Delete zone "${z.name}" from this event?${detail}\n\nClosed incident history will retain its reference to the archived zone. A zone used by an active incident cannot be deleted until that incident is closed or moved.`))return;

    const {error}=await supabase.rpc("admin_archive_event_zone",{p_zone_id:z.id});
    if(error)return alert(error.message);

    await loadAll(activeLayer.id);
  }

  async function setupMap(){if(map){map.remove();map=null;}map=L.map("builderMap",{crs:L.CRS.Simple,minZoom:-4,maxZoom:5,zoomSnap:.25,attributionControl:false});layerGroup=L.layerGroup().addTo(map);if(!activeLayer?.rendered_image_path){map.setView([0,0],0);return;}const url=await signedMapUrl(activeLayer.rendered_image_path);const bounds=[[0,0],[activeLayer.image_height,activeLayer.image_width]];L.imageOverlay(url,bounds).addTo(map);map.fitBounds(bounds);
    for(const cp of points)L.circleMarker(pixelToLeaflet(cp.map_x,cp.map_y,activeLayer.image_height),{radius:6}).addTo(layerGroup).bindTooltip(`CP: ${cp.label}`);
    for(const p of currentPois()){
      const marker=L.marker(pixelToLeaflet(p.map_x,p.map_y,activeLayer.image_height),{icon:poiMapIcon()})
        .addTo(layerGroup)
        .bindTooltip(p.name,{direction:"top",offset:[0,-4]});
      marker.on("click",e=>{
        L.DomEvent.stopPropagation(e);
        showEditPoiForm(p.id);
      });
    }
    for(const n of accessNodes.filter(n=>n.map_layer_id===activeLayer.id)){const ap=accessPoints.find(a=>a.id===n.access_point_id);L.circleMarker(pixelToLeaflet(n.map_x,n.map_y,activeLayer.image_height),{radius:7}).addTo(layerGroup).bindTooltip(`${ap?.name||"Access"} · ${ap?.access_type||""}`);}
    map.on("click",async e=>{
      const px=leafletToPixel(e.latlng,activeLayer.image_height);
      if(clickMode==="control"){
        clickMode=null;
        showControlForm(px);
      }else if(clickMode==="poi"){
        clickMode=null;
        await showPoiForm(px);
      }else if(clickMode?.type==="move-poi"){
        const poiId=clickMode.poiId;
        clickMode=null;
        await movePoiToPixel(poiId,px);
      }else if(clickMode==="access"){
        clickMode=null;
        await showAccessForm(px);
      }
    });
  }
  function showControlForm(px){document.querySelector("#pendingControl").innerHTML=`<div class="card stack"><input id="cpLabel" placeholder="Control point label"><input id="cpLat" placeholder="Latitude"><input id="cpLon" placeholder="Longitude"><button class="btn" id="saveCp">Save Control Point</button></div>`;document.querySelector("#saveCp").onclick=async()=>{const row={event_id:eventId,map_layer_id:activeLayer.id,label:document.querySelector("#cpLabel").value.trim(),map_x:px.x,map_y:px.y,latitude:Number(document.querySelector("#cpLat").value),longitude:Number(document.querySelector("#cpLon").value)};if(!row.label||!Number.isFinite(row.latitude)||!Number.isFinite(row.longitude))return alert("Complete all fields.");const {error}=await supabase.from("map_control_points").insert(row);if(error)alert(error.message);else await loadAll(activeLayer.id);};}
  async function showPoiForm(px){
    const geo=pixelToGeo(px.x,px.y,coeff);
    document.querySelector("#pendingPoi").innerHTML=`<div class="card stack">
      <input id="poiName" placeholder="POI name">
      <select id="poiCategory">
        <option>Seating Section</option><option>Medical</option><option>Command</option><option>Gate</option>
        <option>Portal</option><option>Concession</option><option>Restroom</option><option>Production</option>
        <option>Security</option><option>Other</option>
      </select>
      <select id="poiZone"><option value="">No zone</option>${currentZones().map(z=>`<option value="${z.id}">${esc(z.name)}</option>`).join("")}</select>
      <input id="poiAliases" placeholder="Comma-separated aliases">
      <textarea id="poiNotes" placeholder="Optional notes"></textarea>
      <button class="btn" id="savePoi">Save POI</button>
    </div>`;

    document.querySelector("#savePoi").onclick=async()=>{
      const name=document.querySelector("#poiName").value.trim();
      if(!name)return alert("Enter a POI name.");

      const {data:poi,error}=await supabase.from("event_pois").insert({
        event_id:eventId,
        map_layer_id:activeLayer.id,
        zone_id:document.querySelector("#poiZone").value||null,
        name,
        category:document.querySelector("#poiCategory").value,
        latitude:geo.lat,
        longitude:geo.lon,
        map_x:px.x,
        map_y:px.y,
        notes:document.querySelector("#poiNotes").value.trim()||null
      }).select().single();

      if(error)return alert(error.message);

      const aliases=document.querySelector("#poiAliases").value.split(",").map(x=>x.trim()).filter(Boolean);
      if(aliases.length){
        const {error:aliasError}=await supabase.from("poi_aliases").insert(aliases.map(alias=>({poi_id:poi.id,alias})));
        if(aliasError)return alert(aliasError.message);
      }
      await loadAll(activeLayer.id);
    };
  }


  function showEditPoiForm(poiId){
    const p=pois.find(x=>x.id===poiId);
    if(!p)return alert("POI not found.");
    const aliases=poiAliasList(p).join(", ");

    document.querySelector("#pendingPoi").innerHTML=`<div class="card stack">
      <div class="row">
        <div>
          <div class="section-title">Edit POI</div>
          <strong>${esc(p.name)}</strong>
        </div>
        <span class="badge">${p.poi_scope==="venue_snapshot"?"Venue snapshot":"Event"}</span>
      </div>
      ${p.poi_scope==="venue_snapshot"?`<div class="notice small">This POI came from the venue snapshot. Changes here apply to this event copy only; they do not modify the saved Venue Library version.</div>`:""}
      <label>Name</label>
      <input id="editPoiName" value="${esc(p.name)}" placeholder="POI name">
      <label>Category</label>
      <select id="editPoiCategory">
        ${["Seating Section","Medical","Command","Gate","Portal","Concession","Restroom","Production","Security","Other"].map(category=>`<option value="${esc(category)}" ${p.category===category?"selected":""}>${esc(category)}</option>`).join("")}
      </select>
      <label>Zone</label>
      <select id="editPoiZone"><option value="">No zone</option>${currentZones().map(z=>`<option value="${z.id}" ${p.zone_id===z.id?"selected":""}>${esc(z.name)}</option>`).join("")}</select>
      <label>Aliases</label>
      <input id="editPoiAliases" value="${esc(aliases)}" placeholder="Comma-separated aliases">
      <label>Notes</label>
      <textarea id="editPoiNotes" placeholder="Optional notes">${esc(p.notes||"")}</textarea>
      <div class="small muted">Coordinates: ${Number(p.latitude).toFixed(7)}, ${Number(p.longitude).toFixed(7)}</div>
      <div class="grid2">
        <button class="btn" id="savePoiChanges">Save Changes</button>
        <button class="btn secondary" id="movePoi">Move on Map</button>
      </div>
      <div class="grid2">
        <button class="btn secondary" id="cancelPoiEdit">Cancel</button>
        <button class="btn danger" id="deletePoiFromEdit">Delete POI</button>
      </div>
    </div>`;

    document.querySelector("#savePoiChanges").onclick=()=>savePoiChanges(p);
    document.querySelector("#movePoi").onclick=()=>{
      if(!coeff)return alert("Georeference this layer first.");
      clickMode={type:"move-poi",poiId:p.id};
      document.querySelector("#pendingPoi").innerHTML=`<div class="notice">Click the new location for <strong>${esc(p.name)}</strong> on ${esc(activeLayer.name)}. Its name, category, aliases, zone, and notes will be preserved.</div>`;
    };
    document.querySelector("#cancelPoiEdit").onclick=()=>{clickMode=null;document.querySelector("#pendingPoi").innerHTML="";};
    document.querySelector("#deletePoiFromEdit").onclick=()=>deletePoi(p.id);
  }

  async function savePoiChanges(p){
    const name=document.querySelector("#editPoiName").value.trim();
    if(!name)return alert("Enter a POI name.");

    const aliases=document.querySelector("#editPoiAliases").value
      .split(",")
      .map(x=>x.trim())
      .filter(Boolean);

    const button=document.querySelector("#savePoiChanges");
    button.disabled=true;
    button.textContent="Saving…";

    const {error}=await supabase.rpc("admin_update_event_poi",{
      p_poi_id:p.id,
      p_name:name,
      p_category:document.querySelector("#editPoiCategory").value,
      p_zone_id:document.querySelector("#editPoiZone").value||null,
      p_notes:document.querySelector("#editPoiNotes").value.trim()||null,
      p_aliases:aliases
    });

    if(error){
      button.disabled=false;
      button.textContent="Save Changes";
      return alert(error.message);
    }

    await loadAll(activeLayer.id);
  }

  async function movePoiToPixel(poiId,px){
    const p=pois.find(x=>x.id===poiId);
    if(!p)return alert("POI not found.");
    if(!coeff)return alert("Georeference this layer first.");

    const geo=pixelToGeo(px.x,px.y,coeff);
    const {error}=await supabase.rpc("admin_move_event_poi",{
      p_poi_id:p.id,
      p_map_layer_id:activeLayer.id,
      p_zone_id:p.zone_id||null,
      p_latitude:geo.lat,
      p_longitude:geo.lon,
      p_map_x:px.x,
      p_map_y:px.y
    });

    if(error)return alert(error.message);
    await loadAll(activeLayer.id);
    showEditPoiForm(poiId);
  }

  async function deletePoi(poiId){
    const p=pois.find(x=>x.id===poiId);
    if(!p)return alert("POI not found.");

    const message=`Delete "${p.name}" from this event?\n\nIt will immediately disappear from the active map and POI search. Existing incident/history references are preserved because CommCenter archives the POI rather than physically deleting the database row.`;
    if(!confirm(message))return;

    const {error}=await supabase.rpc("admin_archive_event_poi",{p_poi_id:p.id});
    if(error)return alert(error.message);

    clickMode=null;
    document.querySelector("#pendingPoi").innerHTML="";
    await loadAll(activeLayer.id);
  }

  async function showAccessForm(px){
    const geo=pixelToGeo(px.x,px.y,coeff);
    document.querySelector("#pendingAccess").innerHTML=`<div class="card stack">
      <select id="existingAccess"><option value="">Create new access point</option>${accessPoints.map(a=>`<option value="${a.id}">${esc(a.name)} · ${esc(a.access_type)}</option>`).join("")}</select>
      <input id="accessName" placeholder="Access point name">
      <select id="accessType">
        <option value="elevator">Elevator</option><option value="stairwell">Stairwell</option>
        <option value="escalator">Escalator</option><option value="ramp">Ramp</option>
        <option value="portal">Portal</option><option value="vomitory">Vomitory</option>
        <option value="tunnel">Tunnel</option><option value="gate">Gate</option>
        <option value="corridor">Corridor</option><option value="other">Other</option>
      </select>
      <select id="accessZone"><option value="">No zone</option>${currentZones().map(z=>`<option value="${z.id}">${esc(z.name)}</option>`).join("")}</select>
      <input id="accessInstructions" placeholder="Optional instructions">
      <button class="btn" id="saveAccess">Save Node on ${esc(activeLayer.name)}</button>
    </div>`;

    document.querySelector("#saveAccess").onclick=async()=>{
      let apId=document.querySelector("#existingAccess").value;
      if(!apId){
        const name=document.querySelector("#accessName").value.trim();
        if(!name)return alert("Enter an access-point name.");
        const {data,error}=await supabase.from("venue_access_points").insert({
          event_id:eventId,
          name,
          access_type:document.querySelector("#accessType").value
        }).select().single();
        if(error)return alert(error.message);
        apId=data.id;
      }

      const {error}=await supabase.from("venue_access_point_nodes").upsert({
        access_point_id:apId,
        map_layer_id:activeLayer.id,
        zone_id:document.querySelector("#accessZone").value||null,
        map_x:px.x,
        map_y:px.y,
        latitude:geo.lat,
        longitude:geo.lon,
        instructions:document.querySelector("#accessInstructions").value.trim()||null
      },{onConflict:"access_point_id,map_layer_id"});

      if(error)alert(error.message);else await loadAll(activeLayer.id);
    };
  }

  async function publishLayer(){if(!activeLayer.rendered_image_path||!coeff)return alert("Upload and georeference this layer first.");const makeDefault=document.querySelector("#makeDefault").checked;if(makeDefault)await supabase.from("event_map_layers").update({is_default:false}).eq("event_id",eventId);const {error}=await supabase.from("event_map_layers").update({status:"published",is_default:makeDefault,published_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",activeLayer.id);if(error)alert(error.message);else await loadAll(activeLayer.id);}

  await loadAll();
}
