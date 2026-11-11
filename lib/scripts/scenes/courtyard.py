"""Scenic 庭院灰盒 spec —— scenic 模式的首个场景类型（阶段：scenic-bpy 声明式场景化）。

用法：
    scenic build  courtyard.py -o out/scene_skeleton.glb -p seed=42 -p width=24
    scenic spec   courtyard.py -o out/spec.json -p seed=42

语义分组（顶层 Group 空节点，名字即 layout.json 的 groups[].name）：
    Terrain    地形 / 地面 / 广场石板
    Buildings  围墙、柱列、拱门、门房
    Props      树、长椅、灯柱

所有对象都是参数化几何体 + 纯色 Principled 材质（灰盒），无贴图；
概念图参考平面不在 scenic 模式生成（legacy 模式保留）。
每个可装配实例用 .named() 起唯一名，导出后由 Unity 按名字挂到对应分组。
"""
import math

from scenic import Depends, Field, Scenic
from scenic.geometry import Cube, Cylinder, Group, IcoSphere, Mesh
from scenic.shading import PrincipledBSDF
from scenic.staging import Camera, Render, Scene, SolidWorld, Sun

app = Scenic("courtyard")


# ---------- 材质（灰盒纯色） ----------


@app.material()
def grass():
    return PrincipledBSDF(base_color=(0.32, 0.42, 0.22), roughness=0.95)


@app.material()
def plaza_stone():
    return PrincipledBSDF(base_color=(0.48, 0.46, 0.42), roughness=0.85)


@app.material()
def wall_stone():
    return PrincipledBSDF(base_color=(0.62, 0.58, 0.50), roughness=0.9)


@app.material()
def timber():
    return PrincipledBSDF(base_color=(0.30, 0.20, 0.12), roughness=0.75)


@app.material()
def leaf():
    return PrincipledBSDF(base_color=(0.16, 0.32, 0.10), roughness=0.8)


@app.material()
def iron():
    return PrincipledBSDF(base_color=(0.10, 0.10, 0.12), metallic=0.6, roughness=0.5)


# ---------- 可复用资产（@app.asset，参数化 + seed） ----------


@app.asset()
def column(height: float = Field(3.2, gt=0), stone=Depends(wall_stone)):
    """一根柱：柱身 + 柱头 + 柱础。"""
    return Group(
        [
            Cylinder(radius=0.35, depth=height, vertices=16).at(0, 0, height / 2).shade(stone),
            Cube(size=1).scaled(1.0, 1.0, 0.25).at(0, 0, height + 0.12).shade(stone),
            Cube(size=1).scaled(1.0, 1.0, 0.2).at(0, 0, 0.1).shade(stone),
        ]
    )


@app.asset()
def wall_segment(
    length: float = Field(4.0, gt=0),
    height: float = Field(2.4, gt=0),
    stone=Depends(wall_stone),
):
    """两柱之间的一段矮墙。"""
    return Cube(size=1).scaled(length, 0.5, height).at(0, 0, height / 2).shade(stone)


@app.asset()
def archway(
    width: float = Field(4.0, gt=0),
    height: float = Field(4.4, gt=0),
    stone=Depends(wall_stone),
):
    """拱门：两柱 + 横梁（灰盒，不做弧形拱）。"""
    return Group(
        [
            column(height=height * 0.72).at(-width / 2, 0, 0),
            column(height=height * 0.72).at(width / 2, 0, 0),
            Cube(size=1).scaled(width + 1.2, 0.8, 0.6).at(0, 0, height * 0.72 + 0.3).shade(stone),
        ]
    )


@app.asset()
def pavilion(
    width: float = Field(5.0, gt=0),
    depth: float = Field(4.0, gt=0),
    height: float = Field(4.6, gt=0),
    stone=Depends(wall_stone),
    wood=Depends(timber),
):
    """门房：四柱 + 平顶。"""
    w, d = width / 2, depth / 2
    return Group(
        [
            column(height=height * 0.8).at(-w, -d, 0),
            column(height=height * 0.8).at(w, -d, 0),
            column(height=height * 0.8).at(-w, d, 0),
            column(height=height * 0.8).at(w, d, 0),
            Cube(size=1).scaled(width + 1.4, depth + 1.4, 0.5).at(0, 0, height * 0.8 + 0.25).shade(wood),
            Cube(size=1).scaled(width + 1.6, depth + 1.6, 0.18).at(0, 0, height * 0.8 + 0.6).shade(wood),
        ]
    )


@app.asset()
def tree(seed: int = 0, height: float = Field(4.0, gt=0), wood=Depends(timber), leaves=Depends(leaf)):
    """简单几何树：树干圆柱 + 3 个压扁球冠。"""
    rng = app.rng(f"tree:{seed}")
    crown = []
    for k in range(3):
        crown.append(
            IcoSphere(radius=rng.uniform(0.9, 1.4), subdivisions=1)
            .scaled(1.0, 1.0, rng.uniform(0.8, 1.1))
            .at(rng.uniform(-0.6, 0.6), rng.uniform(-0.6, 0.6), height * 0.55 + k * 0.65)
            .shade(leaves)
        )
    return Group(
        [Cylinder(radius=0.12, depth=height * 0.6, vertices=8).at(0, 0, height * 0.3).shade(wood)] + crown
    )


@app.asset()
def bench(seed: int = 0, wood=Depends(timber)):
    """长椅：座板 + 两条腿。"""
    return Group(
        [
            Cube(size=1).scaled(2.2, 0.55, 0.12).at(0, 0, 0.55).shade(wood),
            Cube(size=1).scaled(0.18, 0.55, 0.5).at(-0.85, 0, 0.25).shade(wood),
            Cube(size=1).scaled(0.18, 0.55, 0.5).at(0.85, 0, 0.25).shade(wood),
        ]
    )


@app.asset()
def lantern(height: float = Field(2.2, gt=0), metal=Depends(iron)):
    """灯柱：细柱 + 顶部灯头。"""
    return Group(
        [
            Cylinder(radius=0.08, depth=height, vertices=8).at(0, 0, height / 2).shade(metal),
            IcoSphere(radius=0.22, subdivisions=1).at(0, 0, height + 0.15).shade(metal),
        ]
    )


# ---------- 场景（@app.scene，参数 width/depth/wall_height/seed） ----------


def ground_height(x: float, y: float) -> float:
    """微弱起伏，避免整块平板；全部对象都落在这个高度函数上。"""
    return 0.18 * math.sin(0.30 * x + 1.1) * math.cos(0.24 * y - 0.7) + 0.12 * math.sin(
        0.55 * x - 0.42 * y
    )


@app.asset()
def terrain(
    width: float = Field(36.0, gt=8),
    depth: float = Field(32.0, gt=8),
    resolution: int = Field(48, ge=16, le=96),
    grass=Depends(grass),
):
    """地形网格：尺寸 = 庭院 + 四周 8 米缓冲。"""
    w, d = width + 8.0, depth + 8.0
    n = resolution
    vertices, faces = [], []
    for j in range(n + 1):
        for i in range(n + 1):
            x = (i / n - 0.5) * w
            y = (j / n - 0.5) * d
            vertices.append((x, y, ground_height(x, y)))
    for j in range(n):
        for i in range(n):
            a = j * (n + 1) + i
            faces.append((a, a + 1, a + n + 2, a + n + 1))
    return Mesh(vertices, faces=faces).smooth_shaded().shade(grass)


@app.scene()
def courtyard(
    width: float = Field(24.0, ge=8, le=60, description="庭院东西向尺寸（米）"),
    depth: float = Field(20.0, ge=8, le=60, description="庭院南北向尺寸（米）"),
    wall_height: float = Field(3.2, ge=1, le=8, description="围墙高度（米）"),
    seed: int = 1,
    ground=Depends(terrain),
    stone=Depends(plaza_stone),
):
    rng = app.rng(f"courtyard:{seed}")
    hw, hd = width / 2, depth / 2
    buildings, props = [], []
    terrain_objs = [
        ground.named("terrain"),
        Cube(size=1).scaled(width * 0.62, depth * 0.62, 0.12).at(0, 0, 0.06).shade(stone).named("plaza"),
    ]

    # 柱列：四角 + 边中点（间距约 4 米），沿围墙一圈
    columns = []  # [(x, y)]
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            columns.append((sx * hw, sy * hd))
    step_x = width / 4.0
    step_y = depth / 4.0
    for i in (1, 2, 3):
        columns.append((-hw + i * step_x, -hd))
        columns.append((-hw + i * step_x, hd))
        columns.append((-hw, -hd + i * step_y))
        columns.append((hw, -hd + i * step_y))

    for index, (x, y) in enumerate(columns, start=1):
        buildings.append(
            column(height=wall_height)
            .at(x, y, ground_height(x, y))
            .named(f"column_{index:02d}")
        )

    # 矮墙：相邻柱之间的边段；南侧中间留给拱门、北侧中间留给门房
    def between(a, b):
        return ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)

    south = [columns[0]] + columns[4:7] + [columns[1]]
    north = [columns[2]] + columns[7:10] + [columns[3]]
    west = [columns[0]] + columns[10:13] + [columns[2]]
    east = [columns[1]] + columns[13:16] + [columns[3]]
    wall_index = 0
    for seq in (south, north, west, east):
        for a, b in zip(seq, seq[1:]):
            mx, my = between(a, b)
            if abs(my) == hd and abs(mx) < 0.01:  # 南/北边正中：留给拱门与门房
                continue
            wall_index += 1
            seg_len = math.hypot(b[0] - a[0], b[1] - a[1])
            buildings.append(
                wall_segment(length=seg_len, height=wall_height * 0.72)
                .rotated(z=math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])))
                .at(mx, my, ground_height(mx, my))
                .named(f"wall_{wall_index:02d}")
            )

    # 南门拱门、北侧门房
    buildings.append(archway(width=4.0, height=wall_height * 1.35).at(0, -hd, ground_height(0, -hd)).named("arch"))
    buildings.append(
        pavilion(width=5.0, depth=4.0, height=wall_height * 1.4)
        .at(0, hd, ground_height(0, hd))
        .named("pavilion")
    )

    # 道具：四角树 + 院中长椅/灯柱
    for k, (sx, sy) in enumerate(((-1, -1), (1, -1), (-1, 1), (1, 1)), start=1):
        x, y = sx * (hw + 3.0), sy * (hd + 3.0)
        props.append(
            tree(seed=seed * 10 + k, height=rng.uniform(3.6, 5.2))
            .rotated(z=rng.uniform(0, 360))
            .at(x, y, ground_height(x, y))
            .named(f"tree_{k:02d}")
        )
    for k, (x, y, rz) in enumerate(
        ((0, -hd * 0.35, 0), (0, hd * 0.35, 180), (-hw * 0.35, 0, 90), (hw * 0.35, 0, -90)), start=1
    ):
        props.append(
            bench(seed=seed * 20 + k).rotated(z=rz).at(x, y, ground_height(x, y)).named(f"bench_{k:02d}")
        )
    for k in range(4):
        a = math.radians(45 + 90 * k)
        x, y = hw * 0.45 * math.cos(a), hd * 0.45 * math.sin(a)
        props.append(
            lantern(height=2.2).at(x, y, ground_height(x, y)).named(f"lantern_{k + 1:02d}")
        )

    return Scene(
        objects=[
            Group(terrain_objs).named("Terrain"),
            Group(buildings).named("Buildings"),
            Group(props).named("Props"),
        ],
        camera=Camera(location=(hw + 9.0, -(hd + 9.0), 12.0), look_at=(0.0, 0.0, 1.2), lens=40),
        lights=[
            Sun(energy=3.4, color=(1.0, 0.94, 0.84), rotation=(52, 0, -138)),
            Sun(energy=0.8, color=(0.45, 0.55, 0.9), rotation=(48, 0, 42)),
        ],
        world=SolidWorld(color="#0a0c10", strength=1.0),
        render=Render(engine="EEVEE", resolution=(1280, 720), samples=32),
    )
