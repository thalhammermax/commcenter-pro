import { supabase } from "./supabase.js";

const esc=(v="")=>String(v).replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[m]));

export async function loadVenueChoices(organizationId){
  const {data,error}=await supabase.rpc("organization_venue_choices",{p_organization_id:organizationId});
  if(error)throw error;
  return data||[];
}

function contentTypeForPath(path){
  const p=String(path||"").toLowerCase();
  if(p.endsWith(".pdf"))return "application/pdf";
  if(p.endsWith(".webp"))return "image/webp";
  if(p.endsWith(".png"))return "image/png";
  if(p.endsWith(".jpg")||p.endsWith(".jpeg"))return "image/jpeg";
  if(p.endsWith(".json"))return "application/json";
  return "application/octet-stream";
}

async function copyStorageObject(sourcePath,destinationPath){
  if(!sourcePath)return null;
  const {data:blob,error:downloadError}=await supabase.storage.from("event-assets").download(sourcePath);
  if(downloadError)throw downloadError;
  const {error:uploadError}=await supabase.storage.from("event-assets").upload(destinationPath,blob,{
    upsert:true,
    contentType:contentTypeForPath(destinationPath)
  });
  if(uploadError)throw uploadError;
  return destinationPath;
}

export async function applyVenueVersionToEvent({eventId,versionId,onProgress=()=>{}}){
  onProgress("Creating event map snapshot…");
  const {data,error}=await supabase.rpc("apply_venue_version_to_event",{
    p_event_id:eventId,
    p_version_id:versionId
  });
  if(error)throw error;

  const payload=data||{};
  const layers=payload.layers||[];

  for(let index=0;index<layers.length;index++){
    const layer=layers[index];
    onProgress(`Copying map layer ${index+1} of ${layers.length}: ${layer.name||"Map"}…`);

    let pdfPath=null;
    let imagePath=null;

    if(layer.source_pdf_path){
      pdfPath=`${eventId}/layers/${layer.event_layer_id}/source.pdf`;
      await copyStorageObject(layer.source_pdf_path,pdfPath);
    }

    if(layer.rendered_image_path){
      imagePath=`${eventId}/layers/${layer.event_layer_id}/map.webp`;
      await copyStorageObject(layer.rendered_image_path,imagePath);
    }

    const {error:updateError}=await supabase.from("event_map_layers").update({
      source_pdf_path:pdfPath,
      rendered_image_path:imagePath,
      status:layer.source_status||"draft",
      published_at:layer.source_published_at||null,
      updated_at:new Date().toISOString()
    }).eq("id",layer.event_layer_id);

    if(updateError)throw updateError;
  }


  onProgress("Venue snapshot ready.");
  return payload;
}

export async function saveEventToVenueLibrary({
  eventId,
  organizationId,
  venueId=null,
  venueName=null,
  address=null,
  notes=null,
  includeEventPois=false,
  onProgress=()=>{}
}){
  onProgress("Creating venue version…");

  const {data,error}=await supabase.rpc("save_event_as_venue_version",{
    p_event_id:eventId,
    p_venue_id:venueId||null,
    p_venue_name:venueName||null,
    p_address:address||null,
    p_notes:notes||null,
    p_include_event_pois:!!includeEventPois
  });
  if(error)throw error;

  const payload=data||{};
  if(payload.organization_id!==organizationId){
    throw new Error("Venue version was created for an unexpected organization.");
  }

  const layers=payload.layers||[];

  for(let index=0;index<layers.length;index++){
    const layer=layers[index];
    onProgress(`Saving map layer ${index+1} of ${layers.length}: ${layer.name||"Map"}…`);

    let pdfPath=null;
    let imagePath=null;
    const base=`venues/${organizationId}/${payload.version_id}/layers/${layer.venue_layer_id}`;

    if(layer.source_pdf_path){
      pdfPath=`${base}/source.pdf`;
      await copyStorageObject(layer.source_pdf_path,pdfPath);
    }

    if(layer.rendered_image_path){
      imagePath=`${base}/map.webp`;
      await copyStorageObject(layer.rendered_image_path,imagePath);
    }

    const {error:updateError}=await supabase.from("organization_venue_map_layers").update({
      source_pdf_path:pdfPath,
      rendered_image_path:imagePath
    }).eq("id",layer.venue_layer_id);

    if(updateError)throw updateError;
  }


  onProgress("Publishing venue version…");
  const {error:publishError}=await supabase.rpc("publish_venue_version",{
    p_version_id:payload.version_id
  });
  if(publishError)throw publishError;

  onProgress(`Saved ${payload.venue_name} v${payload.version_number}.`);
  return payload;
}

export async function renderVenueLibrary(app,organizationId,organizationName,{onBack,onUseVersion}){
  const [venuesRes,versionsRes]=await Promise.all([
    supabase.from("organization_venues").select("*").eq("organization_id",organizationId).eq("active",true).order("name"),
    supabase.from("organization_venue_versions").select("*").order("version_number",{ascending:false})
  ]);
  if(venuesRes.error)throw venuesRes.error;
  if(versionsRes.error)throw versionsRes.error;

  const venues=venuesRes.data||[];
  const venueIds=new Set(venues.map(v=>v.id));
  const versions=(versionsRes.data||[]).filter(v=>venueIds.has(v.venue_id));

  app.innerHTML=`<div class="shell">
    <div class="topbar">
      <div class="brand">CommCenter Pro<small>${esc(organizationName)} · Venue Library</small></div>
      <div class="nav"><button class="btn secondary" id="venueBack">Back to Events</button></div>
    </div>

    <div class="wrap stack">
      <div class="card venue-library-hero">
        <div class="row">
          <div>
            <div class="section-title">Organization Venue Library</div>
            <h2>Reusable Venue Maps</h2>
          </div>
          <span class="badge">${venues.length} venue${venues.length===1?"":"s"}</span>
        </div>
        <p class="muted">A venue version is an immutable template. New events receive their own snapshot, so later venue updates never change historical event maps.</p>
        <div class="notice">
          Build or update a venue in an Event Map Builder, then use <strong>Save / Update Venue Library</strong> in Event Admin.
        </div>
      </div>

      <div class="venue-library-grid">
        ${venues.map(v=>{
          const vv=versions.filter(x=>x.venue_id===v.id);
          const current=vv.find(x=>x.id===v.current_version_id)||vv.find(x=>x.status==="published")||vv[0];
          return `<div class="card venue-library-card">
            <div class="row">
              <div>
                <div class="section-title">${esc(String(v.venue_type||"outdoor").replaceAll("_"," "))}</div>
                <h3>${esc(v.name)}</h3>
              </div>
              ${current?`<span class="badge">v${current.version_number}</span>`:"<span class='badge'>No version</span>"}
            </div>
            ${v.address?`<div class="small muted">${esc(v.address)}</div>`:""}
            ${current?`
              <div class="venue-version-summary">
                <strong>Current published version</strong><br>
                <span class="small muted">${new Date(current.created_at).toLocaleString()}${current.notes?` · ${esc(current.notes)}`:""}</span>
              </div>
              <button class="btn block" data-use-version="${current.id}">Create Event from This Venue</button>
            `:`<p class="muted">No published venue version yet.</p>`}
            ${vv.length>1?`<details><summary>Version history (${vv.length})</summary>
              <div class="venue-version-list">${vv.map(ver=>`<div><strong>v${ver.version_number}</strong> · ${esc(ver.status)}<br><span class="small muted">${new Date(ver.created_at).toLocaleString()}${ver.notes?` · ${esc(ver.notes)}`:""}</span></div>`).join("")}</div>
            </details>`:""}
          </div>`;
        }).join("")||`<div class="card"><h3>No saved venues yet</h3><p class="muted">Open an event, build its maps, then save that setup to the Venue Library.</p></div>`}
      </div>
    </div>
  </div>`;

  document.querySelector("#venueBack").onclick=onBack;
  document.querySelectorAll("[data-use-version]").forEach(btn=>{
    btn.onclick=()=>onUseVersion(btn.dataset.useVersion);
  });
}
