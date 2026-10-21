library(tidyverse)
library(sf)
library(terra)
library(jsonlite)

data <- read.csv("KA-lists.csv")

locs <- data |> distinct(GROUP.ID, .keep_all = TRUE) |>
  select(-SAMPLING.EVENT.IDENTIFIER) |>
  st_as_sf(coords = c("LONGITUDE", "LATITUDE"), crs = 4326)

load("C:/Users/alena/Documents/Work/maps.RData")

ka_map <- dists_sf |> filter(STATE.NAME == "Karnataka")
rm(india_sf, dists_sf, states_sf)


# 5 km grid ----
# Cells are true 5 x 5 km squares in UTM zone 43N, starting from the whole-degree
# lat/long corner below and left of the Karnataka map. Each cell is named after
# its bottom-left corner as "LAT_LONG" with 4 decimals, e.g. "11.0000_74.0000".

utm_crs <- "EPSG:32643"
cell_size <- 5000

origin_ll <- floor(st_bbox(ka_map)[c("xmin", "ymin")])
origin <- st_sfc(st_point(origin_ll), crs = 4326) |> st_transform(utm_crs) |> st_coordinates()
ox <- origin[1, "X"]
oy <- origin[1, "Y"]

ka_utm <- ka_map |> st_transform(utm_crs) |> mutate(DIST.ID = row_number())
ka_bbox <- st_bbox(ka_utm)
locs_xy <- locs |> st_transform(utm_crs) |> st_coordinates()

# Bottom-left corner of cell (i, j) as a lat/long grid name
corner_name <- function(i, j) {
  xy <- tibble(x = ox + i * cell_size, y = oy + j * cell_size) |>
    st_as_sf(coords = c("x", "y"), crs = utm_crs) |>
    st_transform(4326) |>
    st_coordinates()
  sprintf("%.4f_%.4f", xy[, "Y"], xy[, "X"])
}

pt_i <- floor((locs_xy[, "X"] - ox) / cell_size)
pt_j <- floor((locs_xy[, "Y"] - oy) / cell_size)

# Raster template covering the map and every list (some lie off the coast)
i_rng <- range(0, pt_i, ceiling((ka_bbox$xmax - ox) / cell_size) - 1)
j_rng <- range(0, pt_j, ceiling((ka_bbox$ymax - oy) / cell_size) - 1)
template <- rast(xmin = ox + i_rng[1] * cell_size, xmax = ox + (i_rng[2] + 1) * cell_size,
                 ymin = oy + j_rng[1] * cell_size, ymax = oy + (j_rng[2] + 1) * cell_size,
                 resolution = cell_size, crs = utm_crs)

# District of each cell: the one under the cell centre, else any touching it
ka_vect <- vect(ka_utm)
dist_r <- cover(rasterize(ka_vect, template, field = "DIST.ID"),
                rasterize(ka_vect, template, field = "DIST.ID", touches = TRUE))
names(dist_r) <- "DIST.ID"
ka_cells <- as.data.frame(dist_r, xy = TRUE, na.rm = TRUE) |>
  transmute(i = round((x - cell_size / 2 - ox) / cell_size),
            j = round((y - cell_size / 2 - oy) / cell_size),
            DIST.ID = as.integer(DIST.ID))

counts <- tibble(i = pt_i, j = pt_j) |> count(i, j, name = "N.LISTS")

cells <- full_join(ka_cells, counts, by = c("i", "j")) |>
  mutate(N.LISTS = replace_na(N.LISTS, 0L),
         DISTRICT.NAME = coalesce(ka_utm$DISTRICT.NAME[DIST.ID], "Outside Karnataka"),
         GRID.ID = corner_name(i, j))

polys <- map2(cells$i, cells$j, \(i, j) {
  x0 <- ox + i * cell_size
  y0 <- oy + j * cell_size
  st_polygon(list(matrix(c(x0, y0, x0 + cell_size, y0, x0 + cell_size, y0 + cell_size,
                           x0, y0 + cell_size, x0, y0), ncol = 2, byrow = TRUE)))
})
grid <- st_sf(cells, geometry = st_sfc(polys, crs = utm_crs)) |> st_transform(4326)


# Assign every list to its cell ----

locs$GRID.ID <- cells$GRID.ID[match(paste(pt_i, pt_j), paste(cells$i, cells$j))]


# Lists per grid cell ----

grid_summary <- grid |>
  st_drop_geometry() |>
  select(GRID.ID, DISTRICT.NAME, N.LISTS)

grid_summary |>
  summarise(CELLS = n(),
            CELLS.WITH.LISTS = sum(N.LISTS > 0),
            TOTAL.LISTS = sum(N.LISTS),
            MEDIAN.LISTS = median(N.LISTS),
            MAX.LISTS = max(N.LISTS)) |>
  print()


# Interactive map ----
# Cells are drawn in the browser from their (i, j) indices.
# The page loads Leaflet and proj4 from a CDN.

dist_file <- tempfile(fileext = ".geojson")
ka_utm |>
  st_simplify(dTolerance = 100) |>
  st_transform(4326) |>
  select(DISTRICT.NAME) |>
  st_write(dist_file, layer_options = "COORDINATE_PRECISION=5", quiet = TRUE)
dist_geojson <- paste(readLines(dist_file, warn = FALSE), collapse = "")

dist_labels <- ka_utm |>
  st_point_on_surface() |>
  st_transform(4326) |>
  st_coordinates()

ka_bbox_ll <- st_bbox(ka_map)

map_data <- list(
  proj = "+proj=utm +zone=43 +datum=WGS84 +units=m +no_defs",
  origin = c(ox, oy),
  size = cell_size,
  bounds = list(c(ka_bbox_ll$ymin, ka_bbox_ll$xmin), c(ka_bbox_ll$ymax, ka_bbox_ll$xmax)),
  districts = ka_utm$DISTRICT.NAME,
  labels = map(seq_len(nrow(ka_utm)), \(k) list(name = ka_utm$DISTRICT.NAME[k],
                                                lat = dist_labels[k, "Y"],
                                                lon = dist_labels[k, "X"])),
  cells = as.integer(rbind(cells$i, cells$j, cells$N.LISTS, coalesce(cells$DIST.ID, -1L)))
)

html_top <- r"---[<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>KRBC Grids</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/proj4js/2.9.0/proj4.js"></script>
<style>
  html, body, #map { height: 100%; margin: 0; }
  body { font: 13px/1.4 system-ui, -apple-system, "Segoe UI", sans-serif; color: #1f2937; }
  .panel { background: #fff; padding: 10px 12px; border-radius: 6px;
           box-shadow: 0 1px 5px rgba(0,0,0,.35); width: 240px; max-height: 85vh; overflow-y: auto; }
  .panel h3 { margin: 0 0 6px; font-size: 15px; }
  .panel h4 { margin: 0 0 4px; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: #6b7280; }
  .panel label { display: block; margin: 2px 0; cursor: pointer; }
  .panel .sec { margin-top: 10px; border-top: 1px solid #e5e7eb; padding-top: 8px; }
  .legend div { margin: 1px 0; }
  .legend i { display: inline-block; width: 14px; height: 12px; margin-right: 6px; vertical-align: -1px; border: 1px solid #9ca3af; }
  .muted { color: #6b7280; font-size: 12px; }
  .thr { display: flex; align-items: center; gap: 6px; }
  .thr input[type=range] { flex: 1; }
  .thr input[type=number] { width: 58px; }
  button { width: 100%; padding: 6px; margin-top: 6px; cursor: pointer; border: 1px solid #1d4ed8;
           background: #1d4ed8; color: #fff; border-radius: 4px; font: inherit; }
  button:disabled { opacity: .6; cursor: default; }
  .dlabel { font-weight: 600; font-size: 11px; color: #111; white-space: nowrap;
            text-shadow: 0 0 3px #fff, 0 0 3px #fff; transform: translate(-50%, -50%); }
  @media (max-width: 600px) { .panel { width: 200px; } }
</style>
</head>
<body>
<div id="map"></div>
<script>
]---"

html_bottom <- r"---[
proj4.defs('UTM', DATA.proj);
const fwd = proj4('WGS84', 'UTM'), inv = proj4('UTM', 'WGS84');
const OX = DATA.origin[0], OY = DATA.origin[1], S = DATA.size, KM = S / 1000;
const key = (i, j) => (i + 50000) * 100000 + (j + 50000);

// Cells are a flat [i, j, lists, district, ...] array, indexed by (i, j)
const C = DATA.cells, NCELLS = C.length / 4;
const index = new Map();
for (let k = 0; k < C.length; k += 4) index.set(key(C[k], C[k + 1]), k);

let threshold = 10, highlight = true;

const BREAKS = [1, 2, 5, 10, 25, 50, 100];
const COLS = ['#fff7bc', '#fee391', '#fec44f', '#fe9929', '#ec7014', '#cc4c02', '#8c2d04'];
const LABELS = ['1', '2–4', '5–9', '10–24', '25–49', '50–99', '100+'];
const HL = '#1d4ed8';
function colour(n) {
  if (n === 0) return null;
  let c = COLS[0];
  for (let b = 0; b < BREAKS.length; b++) if (n >= BREAKS[b]) c = COLS[b];
  return c;
}

const cornerLL = (i, j) => inv.forward([OX + i * S, OY + j * S]); // [lon, lat]
const cellName = (i, j) => { const p = cornerLL(i, j); return p[1].toFixed(4) + '_' + p[0].toFixed(4); };
const districtName = d => d >= 0 ? DATA.districts[d - 1] : 'Outside Karnataka';

// Map and base layers
const map = L.map('map').fitBounds(DATA.bounds);
const gmap = L.tileLayer('https://mt{s}.google.com/vt/lyrs=m&hl=en&gl=IN&x={x}&y={y}&z={z}', {
  subdomains: '0123', maxZoom: 20, attribution: 'Map data &copy; Google' }).addTo(map);
const sat = L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', {
  maxZoom: 19, attribution: 'Imagery &copy; Esri' });
map.createPane('grid').style.zIndex = 350;

// Grid cells drawn on canvas tiles
const GridLayer = L.GridLayer.extend({
  createTile(coords) {
    const tile = L.DomUtil.create('canvas');
    const ts = this.getTileSize(), dpr = window.devicePixelRatio || 1;
    tile.width = ts.x * dpr; tile.height = ts.y * dpr;
    const ctx = tile.getContext('2d');
    ctx.scale(dpr, dpr);
    const m = this._map, z = coords.z;
    const nw = coords.scaleBy(ts), se = nw.add(ts);
    const xs = [], ys = [];
    [[nw.x, nw.y], [se.x, nw.y], [se.x, se.y], [nw.x, se.y]].forEach(p => {
      const ll = m.unproject(L.point(p[0], p[1]), z);
      const u = fwd.forward([ll.lng, ll.lat]);
      xs.push(u[0]); ys.push(u[1]);
    });
    const i0 = Math.floor((Math.min(...xs) - OX) / S) - 1, i1 = Math.floor((Math.max(...xs) - OX) / S) + 1;
    const j0 = Math.floor((Math.min(...ys) - OY) / S) - 1, j1 = Math.floor((Math.max(...ys) - OY) / S) + 1;

    const cache = new Map();
    const px = (i, j) => {
      const k = key(i, j);
      let v = cache.get(k);
      if (!v) {
        const ll = inv.forward([OX + i * S, OY + j * S]);
        const p = m.project(L.latLng(ll[1], ll[0]), z);
        v = [p.x - nw.x, p.y - nw.y];
        cache.set(k, v);
      }
      return v;
    };
    const path = q => { ctx.beginPath(); ctx.moveTo(q[0][0], q[0][1]); for (let t = 1; t < 4; t++) ctx.lineTo(q[t][0], q[t][1]); ctx.closePath(); };

    const low = [];
    let cellPx = null;
    for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) {
      const k = index.get(key(i, j));
      if (k === undefined) continue;
      const q = [px(i, j), px(i + 1, j), px(i + 1, j + 1), px(i, j + 1)];
      if (cellPx === null) cellPx = Math.hypot(q[1][0] - q[0][0], q[1][1] - q[0][1]);
      path(q);
      const col = colour(C[k + 2]);
      if (col) { ctx.globalAlpha = 0.7; ctx.fillStyle = col; ctx.fill(); ctx.globalAlpha = 1; }
      if (cellPx >= 6) { ctx.lineWidth = 0.5; ctx.strokeStyle = 'rgba(55,65,81,.45)'; ctx.stroke(); }
      if (highlight && C[k + 2] < threshold) low.push(q);
    }
    // Cells below the threshold: blue outline, or blue fill when cells are too small to outline
    low.forEach(q => {
      path(q);
      if (cellPx >= 6) { ctx.lineWidth = 1.6; ctx.strokeStyle = HL; ctx.stroke(); }
      else { ctx.globalAlpha = 0.45; ctx.fillStyle = HL; ctx.fill(); ctx.globalAlpha = 1; }
    });
    return tile;
  }
});
const grid = new GridLayer({ pane: 'grid', updateWhenZooming: false }).addTo(map);

// Districts and their names
const districts = L.geoJSON(DISTRICT_GEO, {
  style: { color: '#111827', weight: 1.3, fill: false }, interactive: false }).addTo(map);
const labels = L.layerGroup(DATA.labels.map(d => L.marker([d.lat, d.lon], {
  interactive: false, keyboard: false,
  icon: L.divIcon({ className: '', html: '<div class="dlabel">' + d.name + '</div>', iconSize: [0, 0] }) })));
let labelsOn = true;
const syncLabels = () => {
  const show = labelsOn && map.getZoom() >= 8;
  if (show && !map.hasLayer(labels)) labels.addTo(map);
  if (!show && map.hasLayer(labels)) map.removeLayer(labels);
};

L.control.layers({ 'Google Maps': gmap, 'Satellite': sat },
                 { 'Grid cells': grid, 'District boundaries': districts }).addTo(map);
L.control.scale({ imperial: false }).addTo(map);

// Click a cell for its details
const sel = L.polygon([], { color: '#dc2626', weight: 2.5, fill: false, interactive: false }).addTo(map);
map.on('click', e => {
  const u = fwd.forward([e.latlng.lng, e.latlng.lat]);
  const i = Math.floor((u[0] - OX) / S), j = Math.floor((u[1] - OY) / S);
  const k = index.get(key(i, j));
  sel.setLatLngs([[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]].map(([a, b]) => {
    const p = cornerLL(a, b); return [p[1], p[0]]; }));
  const n = k === undefined ? 0 : C[k + 2];
  const dist = k === undefined ? 'Outside Karnataka' : districtName(C[k + 3]);
  L.popup().setLatLng(e.latlng).setContent(
    '<b>' + cellName(i, j) + '</b><br>District: ' + dist +
    '<br>Lists: <b>' + n.toLocaleString() + '</b>').openOn(map);
});
map.on('popupclose', () => sel.setLatLngs([]));

// Control panel
const panel = L.control({ position: 'topright' });
panel.onAdd = () => {
  const d = L.DomUtil.create('div', 'panel');
  d.innerHTML =
    '<h3>KRBC ' + KM + ' km grid</h3>' +
    '<div class="muted">' + NCELLS.toLocaleString() + ' cells</div>' +
    '<label><input type="checkbox" id="lbl" checked> District names</label>' +
    '<div class="sec legend"><h4>Lists per cell</h4>' +
    '<div><i style="background:transparent"></i>0</div>' +
    COLS.map((c, x) => '<div><i style="background:' + c + '"></i>' + LABELS[x] + '</div>').join('') + '</div>' +
    '<div class="sec"><h4>Under-sampled cells</h4>' +
    '<label><input type="checkbox" id="hl" checked> Highlight cells with fewer than x lists</label>' +
    '<div class="thr"><input type="range" id="thr" min="1" max="100" value="10"><input type="number" id="thrNum" min="1" value="10"></div>' +
    '<div id="stats" class="muted"></div>' +
    '<button id="dl">Download KML</button></div>';
  L.DomEvent.disableClickPropagation(d);
  L.DomEvent.disableScrollPropagation(d);
  return d;
};
panel.addTo(map);

const $ = id => document.getElementById(id);
function countBelow() {
  let n = 0;
  for (let k = 2; k < C.length; k += 4) if (C[k] < threshold) n++;
  return n;
}
function updateText() {
  const n = countBelow();
  $('stats').textContent = n.toLocaleString() + ' of ' + NCELLS.toLocaleString() +
    ' cells have fewer than ' + threshold + ' lists';
  $('dl').textContent = 'Download KML: ' + n.toLocaleString() + ' cells';
  $('dl').disabled = n === 0;
}
let pending = false;
function redraw() {
  updateText();
  if (pending) return;
  pending = true;
  requestAnimationFrame(() => { pending = false; grid.redraw(); });
}
function setThreshold(v) {
  threshold = Math.max(1, Math.round(+v) || 1);
  $('thr').value = Math.min(threshold, 100);
  $('thrNum').value = threshold;
  redraw();
}

$('thr').addEventListener('input', e => setThreshold(e.target.value));
$('thrNum').addEventListener('input', e => setThreshold(e.target.value));
$('hl').addEventListener('change', e => { highlight = e.target.checked; redraw(); });
$('lbl').addEventListener('change', e => { labelsOn = e.target.checked; syncLabels(); });
map.on('zoomend', syncLabels);

// KML of cells with fewer than x lists
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
$('dl').addEventListener('click', () => {
  const out = ['<?xml version="1.0" encoding="UTF-8"?>\n<kml xmlns="http://www.opengis.net/kml/2.2"><Document>' +
    '<name>KRBC ' + KM + ' km cells with fewer than ' + threshold + ' lists</name>' +
    '<Style id="cell"><LineStyle><color>ffd84e1d</color><width>1.5</width></LineStyle>' +
    '<PolyStyle><color>40d84e1d</color></PolyStyle></Style>\n'];
  for (let k = 0; k < C.length; k += 4) {
    if (C[k + 2] >= threshold) continue;
    const i = C[k], j = C[k + 1];
    const ring = [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1], [i, j]].map(([a, b]) => {
      const p = cornerLL(a, b); return p[0].toFixed(6) + ',' + p[1].toFixed(6) + ',0'; }).join(' ');
    out.push('<Placemark><name>' + cellName(i, j) + '</name><styleUrl>#cell</styleUrl><ExtendedData>' +
      '<Data name="lists"><value>' + C[k + 2] + '</value></Data>' +
      '<Data name="district"><value>' + esc(districtName(C[k + 3])) + '</value></Data></ExtendedData>' +
      '<Polygon><outerBoundaryIs><LinearRing><coordinates>' + ring +
      '</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>\n');
  }
  out.push('</Document></kml>');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob(out, { type: 'application/vnd.google-earth.kml+xml' }));
  a.download = 'krbc-grid-' + KM + 'km-under-' + threshold + '-lists.kml';
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
});

updateText();
syncLabels();
</script>
</body>
</html>
]---"

html <- paste0(html_top,
               "const DATA = ", toJSON(map_data, auto_unbox = TRUE, digits = NA), ";\n",
               "const DISTRICT_GEO = ", dist_geojson, ";\n",
               html_bottom)
writeLines(html, "krbc-grids.html", useBytes = TRUE)
