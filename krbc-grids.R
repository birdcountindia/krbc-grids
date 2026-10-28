library(tidyverse)
library(sf)
library(terra)
library(jsonlite)

data <- read.csv("data/KA-lists.csv")

locs <- data |> distinct(GROUP.ID, .keep_all = TRUE) |>
  st_as_sf(coords = c("LONGITUDE", "LATITUDE"), crs = 4326)

load("C:/Users/alena/Documents/Work/maps.RData")

ka_map <- dists_sf |> filter(STATE.NAME == "Karnataka")
rm(india_sf, dists_sf, states_sf)


# 5 km grid ----
# Cells are true 5 x 5 km squares in UTM zone 43N, starting from the whole-degree
# lat/long corner below and left of the Karnataka map. Each cell belongs to the
# district its centroid falls in, and is named "District_N", numbered within the
# district from north-west to south-east.

utm_crs <- "EPSG:32643"
cell_size <- 5000

origin_ll <- floor(st_bbox(ka_map)[c("xmin", "ymin")])
origin <- st_sfc(st_point(origin_ll), crs = 4326) |> st_transform(utm_crs) |> st_coordinates()
ox <- origin[1, "X"]
oy <- origin[1, "Y"]

ka_utm <- ka_map |> st_transform(utm_crs) |> mutate(DIST.ID = row_number())
ka_bbox <- st_bbox(ka_utm)
locs_xy <- locs |> st_transform(utm_crs) |> st_coordinates()

pt_i <- floor((locs_xy[, "X"] - ox) / cell_size)
pt_j <- floor((locs_xy[, "Y"] - oy) / cell_size)

# Raster template covering the map and every list (some lie off the coast)
i_rng <- range(0, pt_i, ceiling((ka_bbox$xmax - ox) / cell_size) - 1)
j_rng <- range(0, pt_j, ceiling((ka_bbox$ymax - oy) / cell_size) - 1)
template <- rast(xmin = ox + i_rng[1] * cell_size, xmax = ox + (i_rng[2] + 1) * cell_size,
                 ymin = oy + j_rng[1] * cell_size, ymax = oy + (j_rng[2] + 1) * cell_size,
                 resolution = cell_size, crs = utm_crs)

# Cells touching Karnataka, plus any cell with lists
ka_r <- rasterize(vect(ka_utm), template, touches = TRUE)
ka_cells <- as.data.frame(ka_r, xy = TRUE, na.rm = TRUE) |>
  transmute(i = round((x - cell_size / 2 - ox) / cell_size),
            j = round((y - cell_size / 2 - oy) / cell_size))

counts <- tibble(i = pt_i, j = pt_j) |> count(i, j, name = "N.LISTS")

cells <- full_join(ka_cells, counts, by = c("i", "j")) |>
  mutate(N.LISTS = replace_na(N.LISTS, 0L))

# Centroids, and the district each falls in (nearest district if it falls
# outside all of them, along the state border or the coast)
centroids <- cells |>
  transmute(x = ox + (i + 0.5) * cell_size, y = oy + (j + 0.5) * cell_size) |>
  st_as_sf(coords = c("x", "y"), crs = utm_crs)

dist_id <- st_intersects(centroids, ka_utm) |> map_int(\(d) d[1] %||% NA_integer_)
outside <- is.na(dist_id)
dist_id[outside] <- st_nearest_feature(centroids[outside, ], ka_utm)

centroids_ll <- centroids |> st_transform(4326) |> st_coordinates()

cells <- cells |>
  mutate(DIST.ID = dist_id,
         DISTRICT.NAME = ka_utm$DISTRICT.NAME[DIST.ID],
         CENTROID.OUTSIDE.KA = outside,
         CENTROID.LAT = round(centroids_ll[, "Y"], 5),
         CENTROID.LON = round(centroids_ll[, "X"], 5)) |>
  arrange(DISTRICT.NAME, desc(j), i) |>
  mutate(CELL.NO = row_number(), .by = DISTRICT.NAME) |>
  mutate(GRID.ID = paste0(DISTRICT.NAME, "_", CELL.NO))

polys <- map2(cells$i, cells$j, \(i, j) {
  x0 <- ox + i * cell_size
  y0 <- oy + j * cell_size
  st_polygon(list(matrix(c(x0, y0, x0 + cell_size, y0, x0 + cell_size, y0 + cell_size,
                           x0, y0 + cell_size, x0, y0), ncol = 2, byrow = TRUE)))
})
grid <- st_sf(cells, geometry = st_sfc(polys, crs = utm_crs)) |> st_transform(4326)


# Assign every list to its cell ----

cell_of_list <- match(paste(pt_i, pt_j), paste(cells$i, cells$j))
locs$GRID.ID <- cells$GRID.ID[cell_of_list]
locs$GRID.DISTRICT <- cells$DISTRICT.NAME[cell_of_list]


# Lists per grid cell ----

grid_summary <- grid |>
  st_drop_geometry() |>
  select(GRID.ID, DISTRICT.NAME, CELL.NO, CENTROID.LAT, CENTROID.LON, N.LISTS)

grid_summary |>
  summarise(CELLS = n(),
            CELLS.WITH.LISTS = sum(N.LISTS > 0),
            TOTAL.LISTS = sum(N.LISTS),
            MEDIAN.LISTS = median(N.LISTS),
            MAX.LISTS = max(N.LISTS)) |>
  print()


# Data for the map (index.html, hosted on GitHub Pages) ----
# Cells are stored as their (i, j) indices and drawn in the browser.

dir.create("data", showWarnings = FALSE)

ka_utm |>
  st_simplify(dTolerance = 100) |>
  st_transform(4326) |>
  select(DISTRICT.NAME) |>
  st_write("data/districts.geojson", layer_options = "COORDINATE_PRECISION=5",
           delete_dsn = TRUE, quiet = TRUE)

dist_labels <- ka_utm |>
  st_point_on_surface() |>
  st_transform(4326) |>
  st_coordinates()

ka_bbox_ll <- st_bbox(ka_map)

list(
  updated = format(Sys.Date()),
  proj = "+proj=utm +zone=43 +datum=WGS84 +units=m +no_defs",
  origin = c(ox, oy),
  size = cell_size,
  bounds = list(c(ka_bbox_ll$ymin, ka_bbox_ll$xmin), c(ka_bbox_ll$ymax, ka_bbox_ll$xmax)),
  districts = ka_utm$DISTRICT.NAME,
  labels = map(seq_len(nrow(ka_utm)), \(k) list(name = ka_utm$DISTRICT.NAME[k],
                                                lat = dist_labels[k, "Y"],
                                                lon = dist_labels[k, "X"])),
  cells = as.integer(rbind(cells$i, cells$j, cells$N.LISTS, cells$DIST.ID, cells$CELL.NO))
) |>
  write_json("data/grid.json", auto_unbox = TRUE, digits = NA)
