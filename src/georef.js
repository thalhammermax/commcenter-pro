const EARTH_M_PER_DEG_LAT = 111320;

function solve3(A, b) {
  const m = A.map((row, i) => [...row, b[i]]);

  for (let col = 0; col < 3; col++) {
    let pivot = col;
    for (let r = col + 1; r < 3; r++) {
      if (Math.abs(m[r][col]) > Math.abs(m[pivot][col])) pivot = r;
    }
    if (Math.abs(m[pivot][col]) < 1e-12) throw new Error("Control points do not produce a solvable transform.");
    [m[col], m[pivot]] = [m[pivot], m[col]];

    const d = m[col][col];
    for (let c = col; c < 4; c++) m[col][c] /= d;

    for (let r = 0; r < 3; r++) {
      if (r === col) continue;
      const f = m[r][col];
      for (let c = col; c < 4; c++) m[r][c] -= f * m[col][c];
    }
  }
  return [m[0][3], m[1][3], m[2][3]];
}

function fitOne(points, targetKey) {
  let sx=0, sy=0, sxx=0, syy=0, sxy=0, st=0, sxt=0, syt=0;
  for (const p of points) {
    const x=Number(p.map_x), y=Number(p.map_y), t=Number(p[targetKey]);
    sx+=x; sy+=y; sxx+=x*x; syy+=y*y; sxy+=x*y; st+=t; sxt+=x*t; syt+=y*t;
  }
  const n=points.length;
  return solve3(
    [[n,sx,sy],[sx,sxx,sxy],[sy,sxy,syy]],
    [st,sxt,syt]
  );
}

export function fitAffine(points) {
  if (points.length < 3) throw new Error("At least 3 control points are required.");
  const lat = fitOne(points, "latitude");
  const lon = fitOne(points, "longitude");

  const residuals = points.map(p => {
    const predicted = pixelToGeo(Number(p.map_x), Number(p.map_y), {lat, lon});
    const meters = distanceMeters(Number(p.latitude), Number(p.longitude), predicted.lat, predicted.lon);
    return { id:p.id, label:p.label, meters, predicted };
  });

  const rmse = Math.sqrt(residuals.reduce((s,r)=>s+r.meters*r.meters,0)/residuals.length);
  const max = Math.max(...residuals.map(r=>r.meters));
  return { coefficients:{lat,lon}, residuals, rmse, max };
}

export function pixelToGeo(x, y, coefficients) {
  const a=coefficients.lat, b=coefficients.lon;
  return {
    lat:a[0]+a[1]*x+a[2]*y,
    lon:b[0]+b[1]*x+b[2]*y
  };
}

export function distanceMeters(lat1, lon1, lat2, lon2) {
  const avg = (lat1+lat2)/2 * Math.PI/180;
  const dy=(lat2-lat1)*EARTH_M_PER_DEG_LAT;
  const dx=(lon2-lon1)*EARTH_M_PER_DEG_LAT*Math.cos(avg);
  return Math.sqrt(dx*dx+dy*dy);
}

export function leafletToPixel(latlng, imageHeight) {
  return { x:latlng.lng, y:imageHeight-latlng.lat };
}

export function pixelToLeaflet(x, y, imageHeight) {
  return [imageHeight-y, x];
}


export function geoToPixel(lat, lon, coefficients) {
  const a=coefficients.lat, b=coefficients.lon;
  const A=a[1], B=a[2], C=b[1], D=b[2];
  const u=lat-a[0], v=lon-b[0];
  const det=A*D-B*C;
  if (Math.abs(det) < 1e-16) throw new Error("Georeference transform is not invertible.");
  return {
    x:(u*D-B*v)/det,
    y:(A*v-u*C)/det
  };
}
