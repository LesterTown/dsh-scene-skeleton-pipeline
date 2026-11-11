using System;
using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;

/// <summary>
/// dsh-scene-skeleton-pipeline 的 Unity 编辑器入口（阶段 6：按布局 JSON 装配场景骨架，
/// 支持 scenic 模式的 .glb（一个资产内多个节点）与 legacy 模式的 .fbx）。
///
/// 由插件自动写入项目 Assets/Editor/ 下，通过 batchmode 调用：
///   Unity -batchmode -quit -projectPath <项目> -executeMethod SceneSkeletonPipelineEditor.Build
///
/// 输入 Assets/SceneSkeletonPipeline/input.json：
///   { layoutPath, resultPath, assetPath（scenic .glb；legacy 用 fbxPath）, fbxPath, scenePath, title }
///
/// 装配流程（layout.json 契约见插件 lib/layout.js 顶部注释）：
///   1. 建根节点 layout.root；
///   2. 按 groups[].name 建分组空节点，objects[] 逐个从网格资产取节点（按 instanceName
///      在资产树里找子节点并设置 transform；同一资产可被多个对象复用）；
///   3. 按 lighting 配环境光、方向光、天空盒；
///   4. 按 camera 建/复用 Main Camera，position + LookAt；
///   5. prefab.enabled 时把整棵树存成 Assets/Prefabs/&lt;sceneName&gt;.prefab；
///   6. 保存 .unity 场景，并把结构化结果写到 resultPath（unity-result.json）。
/// </summary>
public static class SceneSkeletonPipelineEditor
{
    private const string InputRelativePath = "Assets/SceneSkeletonPipeline/input.json";
    private const int MaxReportLogs = 40;

    public static void Build()
    {
        List<string> logs = new List<string>();
        string projectRoot = Path.GetFullPath(Path.Combine(Application.dataPath, ".."));
        string resultPath = "";
        BuildReport report = new BuildReport
        {
            success = false,
            scenePath = "",
            root = "",
            groups = new string[0],
            objectCount = 0,
            prefabPath = "",
            layoutPath = "",
            logs = new string[0],
        };

        try
        {
            string inputPath = Path.Combine(projectRoot, InputRelativePath);
            if (!File.Exists(inputPath))
            {
                throw new Exception("input.json not found: " + inputPath);
            }

            BuildInput payload = JsonUtility.FromJson<BuildInput>(File.ReadAllText(inputPath));
            if (payload == null)
            {
                throw new Exception("input.json 解析失败: " + inputPath);
            }
            resultPath = string.IsNullOrEmpty(payload.resultPath)
                ? Path.Combine(projectRoot, "unity-result.json")
                : payload.resultPath;

            if (string.IsNullOrEmpty(payload.layoutPath) || !File.Exists(payload.layoutPath))
            {
                throw new Exception("layout.json 不存在: " + payload.layoutPath);
            }
            if (string.IsNullOrEmpty(payload.scenePath))
            {
                throw new Exception("input.json 缺少 scenePath");
            }

            LayoutRoot layout = JsonUtility.FromJson<LayoutRoot>(File.ReadAllText(payload.layoutPath));
            if (layout == null || string.IsNullOrEmpty(layout.root) || layout.groups == null || layout.groups.Length == 0)
            {
                throw new Exception("layout.json 缺少 root / groups: " + payload.layoutPath);
            }
            report.layoutPath = payload.layoutPath;
            logs.Add("layout: " + payload.layoutPath);

            AssetDatabase.Refresh(ImportAssetOptions.ForceSynchronousImport);
            string modelPath = string.IsNullOrEmpty(payload.assetPath) ? payload.fbxPath : payload.assetPath;
            EnsureModelImportSettings(modelPath, projectRoot, logs);

            Scene scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            GameObject root = new GameObject(layout.root);
            AssetRegistry registry = new AssetRegistry(projectRoot, logs);
            List<string> groupNames = new List<string>();
            int objectCount = 0;

            foreach (LayoutGroup group in layout.groups)
            {
                if (group == null || string.IsNullOrEmpty(group.name))
                {
                    continue;
                }
                GameObject groupObject = new GameObject(group.name);
                groupObject.transform.SetParent(root.transform, false);
                groupNames.Add(group.name);

                if (group.objects == null)
                {
                    continue;
                }
                foreach (LayoutObject item in group.objects)
                {
                    if (item == null)
                    {
                        continue;
                    }
                    GameObject placed = registry.Place(item, groupObject.transform, logs);
                    if (placed != null)
                    {
                        objectCount += 1;
                    }
                }
            }
            registry.DestroyLeftovers();

            ApplyLighting(layout.lighting);
            ApplyCamera(layout.camera);

            string prefabPath = "";
            if (layout.prefab != null && layout.prefab.enabled)
            {
                prefabPath = SavePrefab(root, layout, projectRoot, logs);
            }

            string sceneDirectory = Path.GetDirectoryName(Path.Combine(projectRoot, payload.scenePath));
            if (!string.IsNullOrEmpty(sceneDirectory))
            {
                Directory.CreateDirectory(sceneDirectory);
            }
            bool saved = EditorSceneManager.SaveScene(scene, payload.scenePath);
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();

            report.success = true;
            report.scenePath = payload.scenePath;
            report.root = layout.root;
            report.groups = groupNames.ToArray();
            report.objectCount = objectCount;
            report.prefabPath = prefabPath;

            WriteBoundsReport(root.transform, logs);

            logs.Add("scene saved=" + saved + " path=" + payload.scenePath);
            Debug.Log("DSH_UNITY_SCENE_OK:" + payload.scenePath + ":saved=" + saved + ":root=" + layout.root +
                      ":objects=" + objectCount + ":groups=" + groupNames.Count +
                      ":prefab=" + (string.IsNullOrEmpty(prefabPath) ? "none" : prefabPath));
            WriteReport(report, logs, resultPath);
            Debug.Log("DSH_UNITY_RESULT:" + resultPath);
        }
        catch (Exception error)
        {
            logs.Add("ERROR: " + error);
            Debug.LogError("DSH_UNITY_SCENE_ERROR:" + error);
            WriteReport(report, logs, resultPath);
            EditorApplication.Exit(1);
        }
    }

    /// <summary>
    /// 可选的尺寸自检（验证脚本使用）：设置环境变量 DSH_UNITY_BOUNDS_OUT 后，
    /// 把根节点下所有 Renderer 的世界包围盒尺寸写成 `name|sx|sy|sz` 行。
    /// 回归脚本据此断言「装配后的世界尺寸是米制」，防止 100 倍缩放类回归。
    /// </summary>
    private static void WriteBoundsReport(Transform root, List<string> logs)
    {
        string path = Environment.GetEnvironmentVariable("DSH_UNITY_BOUNDS_OUT");
        if (string.IsNullOrEmpty(path) || root == null)
        {
            return;
        }
        try
        {
            List<string> lines = new List<string>();
            foreach (Renderer renderer in root.GetComponentsInChildren<Renderer>(true))
            {
                Bounds bounds = renderer.bounds;
                lines.Add(
                    renderer.gameObject.name + "|" +
                    bounds.size.x.ToString("F3") + "|" +
                    bounds.size.y.ToString("F3") + "|" +
                    bounds.size.z.ToString("F3"));
            }
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            File.WriteAllLines(path, lines.ToArray());
            logs.Add("bounds report=" + path + " renderers=" + lines.Count);
            Debug.Log("DSH_UNITY_BOUNDS:" + path + ":renderers=" + lines.Count);
        }
        catch (Exception error)
        {
            Debug.LogWarning("DSH_UNITY_BOUNDS_ERROR:" + error.Message);
        }
    }

    private static void WriteReport(BuildReport report, List<string> logs, string resultPath)
    {
        try
        {
            if (string.IsNullOrEmpty(resultPath))
            {
                resultPath = Path.Combine(Path.GetFullPath(Path.Combine(Application.dataPath, "..")), "unity-result.json");
            }
            int start = Mathf.Max(0, logs.Count - MaxReportLogs);
            report.logs = logs.GetRange(start, logs.Count - start).ToArray();
            string directory = Path.GetDirectoryName(resultPath);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            File.WriteAllText(resultPath, JsonUtility.ToJson(report, true));
        }
        catch (Exception error)
        {
            Debug.LogError("DSH_UNITY_RESULT_WRITE_ERROR:" + error);
        }
    }

    private static void ApplyLighting(LayoutLighting lighting)
    {
        if (lighting == null)
        {
            return;
        }

        RenderSettings.ambientMode = AmbientMode.Flat;
        if (lighting.ambient != null)
        {
            Color ambient = ToColor(lighting.ambient.color);
            RenderSettings.ambientLight = ambient * Mathf.Max(0f, lighting.ambient.intensity);
        }

        if (lighting.directional != null)
        {
            GameObject lightObject = new GameObject("Directional Light");
            Light light = lightObject.AddComponent<Light>();
            light.type = LightType.Directional;
            light.intensity = Mathf.Max(0f, lighting.directional.intensity);
            light.color = ToColor(lighting.directional.color);
            lightObject.transform.rotation = Quaternion.Euler(ToVector3(lighting.directional.rotation));
        }

        if (lighting.skybox == "default")
        {
            Material sky = AssetDatabase.GetBuiltinExtraResource<Material>("Default-Skybox.mat");
            if (sky != null)
            {
                RenderSettings.skybox = sky;
            }
        }
        else
        {
            RenderSettings.skybox = null;
        }
    }

    private static void ApplyCamera(LayoutCamera camera)
    {
        Vector3 position = camera != null ? ToVector3(camera.position, new Vector3(15f, 12f, 15f)) : new Vector3(15f, 12f, 15f);
        Vector3 lookAt = camera != null ? ToVector3(camera.lookAt) : Vector3.zero;

        Camera existing = Camera.main;
        GameObject cameraObject;
        if (existing != null)
        {
            cameraObject = existing.gameObject;
        }
        else
        {
            cameraObject = new GameObject("Main Camera");
            cameraObject.AddComponent<Camera>();
            cameraObject.tag = "MainCamera";
        }
        cameraObject.transform.position = position;
        cameraObject.transform.LookAt(lookAt);
    }

    private static string SavePrefab(GameObject root, LayoutRoot layout, string projectRoot, List<string> logs)
    {
        string directory = layout.prefab != null && !string.IsNullOrEmpty(layout.prefab.path)
            ? layout.prefab.path.Replace('\\', '/')
            : "Assets/Prefabs/";
        if (!directory.StartsWith("Assets/"))
        {
            directory = "Assets/" + directory.TrimStart('/');
        }
        if (!directory.EndsWith("/"))
        {
            directory += "/";
        }
        string absolute = Path.Combine(projectRoot, directory);
        Directory.CreateDirectory(absolute);

        string fileName = string.IsNullOrEmpty(layout.sceneName) ? "SceneSkeleton" : layout.sceneName;
        string prefabPath = directory + fileName + ".prefab";
        PrefabUtility.SaveAsPrefabAsset(root, prefabPath);
        logs.Add("prefab: " + prefabPath);
        return prefabPath;
    }

    private static Vector3 ToVector3(float[] values, Vector3 fallback = default)
    {
        if (values == null || values.Length < 3)
        {
            return fallback == default ? Vector3.zero : fallback;
        }
        return new Vector3(values[0], values[1], values[2]);
    }

    /// <summary>
    /// 固定 fbx 的导入设置：启用 Convert Units、globalScale=1。
    /// Blender 导出的 fbx 以厘米为单位、节点上带 100 倍换算，这组设置才能让 1 单位 = 1 米；
    /// 用户或历史 meta 改了这两项时，几何会整体大/小 100 倍，所以每次装配前校正一次。
    /// </summary>
    private static void EnsureModelImportSettings(string fbxPath, string projectRoot, List<string> logs)
    {
        if (string.IsNullOrEmpty(fbxPath))
        {
            return;
        }
        string relative = fbxPath.Replace('\\', '/');
        string root = projectRoot.Replace('\\', '/').TrimEnd('/');
        if (relative.StartsWith(root + "/"))
        {
            relative = relative.Substring(root.Length + 1);
        }
        if (!relative.StartsWith("Assets/"))
        {
            logs.Add("跳过 fbx 导入设置校正：路径不在 Assets 下 " + relative);
            return;
        }
        ModelImporter importer = AssetImporter.GetAtPath(relative) as ModelImporter;
        if (importer == null)
        {
            logs.Add("警告：读不到 fbx 导入设置 " + relative);
            return;
        }
        bool changed = false;
        if (!importer.useFileScale)
        {
            importer.useFileScale = true;
            changed = true;
        }
        if (!Mathf.Approximately(importer.globalScale, 1f))
        {
            importer.globalScale = 1f;
            changed = true;
        }
        if (!changed)
        {
            return;
        }
        importer.SaveAndReimport();
        AssetDatabase.Refresh(ImportAssetOptions.ForceSynchronousImport);
        logs.Add("校正 fbx 导入设置：useFileScale=true globalScale=1 (" + relative + ")");
    }

    private static Color ToColor(float[] values)
    {
        if (values == null || values.Length < 3)
        {
            return Color.white;
        }
        return new Color(values[0], values[1], values[2], 1f);
    }

    /// <summary>按资产路径缓存 fbx 实例，把布局里的对象从实例树中取出来挂到分组下。</summary>
    private sealed class AssetRegistry
    {
        private readonly string _projectRoot;
        private readonly List<string> _logs;
        private readonly Dictionary<string, GameObject> _instances = new Dictionary<string, GameObject>();
        private readonly Dictionary<string, Transform> _nodes = new Dictionary<string, Transform>();

        public AssetRegistry(string projectRoot, List<string> logs)
        {
            _projectRoot = projectRoot;
            _logs = logs;
        }

        public GameObject Place(LayoutObject item, Transform parent, List<string> logs)
        {
            string assetPath = ResolveAssetPath(item.asset);
            if (string.IsNullOrEmpty(assetPath))
            {
                logs.Add("跳过 " + item.instanceName + "：找不到资产 " + item.asset);
                return null;
            }

            GameObject instance = GetInstance(assetPath);
            if (instance == null)
            {
                logs.Add("跳过 " + item.instanceName + "：资产加载失败 " + assetPath);
                return null;
            }

            Transform node;
            if (!_nodes.TryGetValue(item.instanceName, out node) || node == null)
            {
                node = FindDeepChild(instance.transform, item.instanceName);
            }
            if (node == null)
            {
                logs.Add("警告：" + item.instanceName + " 在 " + assetPath + " 中找不到，改用整个 fbx 实例");
                node = instance.transform;
            }

            // 用 SetParent(parent, true)（保持世界变换）：fbx 导入时 Unity 把 cm→m 的单位换算
            // 放在层级根节点（scale=100）上，节点自身的 localScale 是 1；用 false 重挂会把
            // 换算因子丢掉、几何小 100 倍。
            // 注意：对「旋转 + 非均匀缩放」的节点，SetParent(true) 的分解结果 localScale 与
            // localRotation 是一对（世界矩阵 = T·R·S）；之后覆盖 localRotation 会破坏配对，
            // 导致非均匀缩放在旋转系里被二次应用（plaza/wall 曾出现 22141 这类错误值）。
            // 因此先记下世界缩放 lossyScale，重挂后显式赋回：父节点恒为单位变换，
            // local == world。
            Vector3 worldScale = node.lossyScale;
            node.SetParent(parent, true);
            Transform transform = node;
            transform.localPosition = ToVector3(item.position);
            transform.localRotation = Quaternion.Euler(ToVector3(item.rotation));
            // layout.scale 是“实例额外缩放”，按乘法应用在带换算因子的世界缩放之上。
            Vector3 extraScale = ToVector3(item.scale, Vector3.one);
            transform.localScale = new Vector3(
                worldScale.x * extraScale.x,
                worldScale.y * extraScale.y,
                worldScale.z * extraScale.z);
            if (transform.name != item.instanceName && !string.IsNullOrEmpty(item.instanceName))
            {
                transform.name = item.instanceName;
            }
            logs.Add("place " + transform.name + " -> " + parent.name);
            return transform.gameObject;
        }

        private GameObject GetInstance(string assetPath)
        {
            GameObject cached;
            if (_instances.TryGetValue(assetPath, out cached) && cached != null)
            {
                return cached;
            }
            GameObject asset = AssetDatabase.LoadAssetAtPath<GameObject>(assetPath);
            if (asset == null)
            {
                return null;
            }
            GameObject instance = (GameObject)PrefabUtility.InstantiatePrefab(asset);
            if (instance == null)
            {
                return null;
            }
            if (PrefabUtility.IsPartOfPrefabInstance(instance))
            {
                PrefabUtility.UnpackPrefabInstance(instance, PrefabUnpackMode.Completely, InteractionMode.AutomatedAction);
            }
            _instances[assetPath] = instance;
            RegisterTree(instance.transform, _nodes);
            _logs.Add("instance " + assetPath + " (" + instance.transform.childCount + " children)");
            return instance;
        }

        private static void RegisterTree(Transform transform, Dictionary<string, Transform> nodes)
        {
            if (!nodes.ContainsKey(transform.name))
            {
                nodes[transform.name] = transform;
            }
            for (int index = 0; index < transform.childCount; index += 1)
            {
                RegisterTree(transform.GetChild(index), nodes);
            }
        }

        private string ResolveAssetPath(string asset)
        {
            if (string.IsNullOrEmpty(asset))
            {
                return "";
            }
            string normalized = asset.Replace('\\', '/');
            if (normalized.StartsWith("Assets/"))
            {
                return AssetDatabase.LoadAssetAtPath<GameObject>(normalized) != null ? normalized : "";
            }
            string direct = "Assets/SceneSkeletonPipeline/" + normalized;
            if (AssetDatabase.LoadAssetAtPath<GameObject>(direct) != null)
            {
                return direct;
            }
            string fileName = Path.GetFileName(normalized);
            string[] guids = AssetDatabase.FindAssets(Path.GetFileNameWithoutExtension(normalized), new[] { "Assets" });
            foreach (string guid in guids)
            {
                string path = AssetDatabase.GUIDToAssetPath(guid);
                if (Path.GetFileName(path) == fileName)
                {
                    return path;
                }
            }
            return "";
        }

        public void DestroyLeftovers()
        {
            // 所有具名节点都已被 Place() 重新挂到分组下；剩下的实例树只是
            // 被掏空的资产层级（glb 里的 Terrain/Buildings/Props 空节点等），
            // 整个销毁即可，避免场景根下残留空壳。
            foreach (GameObject instance in _instances.Values)
            {
                if (instance != null)
                {
                    UnityEngine.Object.DestroyImmediate(instance);
                }
            }
            _instances.Clear();
        }

        private static Transform FindDeepChild(Transform parent, string name)
        {
            if (parent == null || string.IsNullOrEmpty(name))
            {
                return null;
            }
            for (int index = 0; index < parent.childCount; index += 1)
            {
                Transform child = parent.GetChild(index);
                if (child.name == name)
                {
                    return child;
                }
                Transform nested = FindDeepChild(child, name);
                if (nested != null)
                {
                    return nested;
                }
            }
            return null;
        }
    }

    [Serializable]
    public class BuildInput
    {
        public string layoutPath;
        public string resultPath;
        public string assetPath;
        public string fbxPath;
        public string scenePath;
        public string title;
    }

    [Serializable]
    public class LayoutRoot
    {
        public string sceneName;
        public string root;
        public LayoutGroup[] groups;
        public LayoutLighting lighting;
        public LayoutCamera camera;
        public LayoutPrefab prefab;
    }

    [Serializable]
    public class LayoutGroup
    {
        public string name;
        public LayoutObject[] objects;
    }

    [Serializable]
    public class LayoutObject
    {
        public string asset;
        public string instanceName;
        public float[] position;
        public float[] rotation;
        public float[] scale;
    }

    [Serializable]
    public class LayoutLighting
    {
        public LayoutAmbient ambient;
        public LayoutDirectional directional;
        public string skybox;
    }

    [Serializable]
    public class LayoutAmbient
    {
        public float intensity;
        public float[] color;
    }

    [Serializable]
    public class LayoutDirectional
    {
        public float intensity;
        public float[] rotation;
        public float[] color;
    }

    [Serializable]
    public class LayoutCamera
    {
        public float[] position;
        public float[] lookAt;
    }

    [Serializable]
    public class LayoutPrefab
    {
        public bool enabled;
        public string path;
    }

    [Serializable]
    public class BuildReport
    {
        public bool success;
        public string scenePath;
        public string root;
        public string[] groups;
        public int objectCount;
        public string prefabPath;
        public string layoutPath;
        public string[] logs;
    }
}
