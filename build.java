import java.io.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.stream.Stream;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;

/**
 * Script de compilation intelligent pour projets Maven avec gestion de cache optimisé.
 */
public class MavenSmartBuilder {
    
    private static final Set<String> EXTENSIONS_TO_HASH = Set.of("java", "xml", "properties", "txt", "json", "yml", "yaml");
    private static final Set<String> EXCLUSIONS = Set.of("target", "build", ".idea", ".git", "node_modules");
    private static final String HASH_ALGORITHM = "SHA-256";
    private static final int BUFFER_SIZE = 16384; // 16KB buffer pour lecture fichiers
    private static final String CACHE_FILE = "hash.properties";
    private static final String MODULE_PREFIX = "module.";
    
    // Configuration immutable
    private final String projectPath;
    private final String cacheRoot;
    private final boolean forceRebuild;
    private final boolean init;
    private final boolean useGit;
    private final String specificModule;
    
    // Cache réutilisable
    private final DocumentBuilder xmlParser;
    private final MessageDigest hasher;
    
    public static void main(String[] args) {
        try {
            new MavenSmartBuilder(args).execute();
        } catch (Exception e) {
            System.err.println("❌ " + e.getMessage());
            System.exit(1);
        }
    }
    
    public MavenSmartBuilder(String[] args) throws Exception {
        Map<String, String> params = parseArgs(args);
        
        this.projectPath = validateRequired(params.get("p"), "Paramètre -p (chemin du projet) obligatoire");
        this.specificModule = params.get("m");
        this.forceRebuild = params.containsKey("ForceRebuild");
        this.init = params.containsKey("Init");
        this.useGit = params.containsKey("UseGit");
        
        // Validation et initialisation
        validateProjectStructure();
        ProjectInfo projectInfo = readProjectInfo();
        this.cacheRoot = Paths.get(System.getProperty("user.home"), ".m2", "cache", 
            projectInfo.artifactId + "-" + projectInfo.version).toString();
        
        // Initialisation des parsers réutilisables
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setValidating(false);
        factory.setNamespaceAware(false);
        this.xmlParser = factory.newDocumentBuilder();
        this.hasher = MessageDigest.getInstance(HASH_ALGORITHM);
        
        System.out.println("🚀 Projet: " + projectInfo.artifactId + "-" + projectInfo.version);
    }
    
    public void execute() throws Exception {
        ProjectData projectData = scanModules();
        
        if (projectData.modules.isEmpty()) {
            throw new RuntimeException("Aucun module trouvé");
        }
        
        if (init) {
            initializeCache(projectData.modules);
            return;
        }
        
        List<String> modulesToBuild = determineModulesToBuild(projectData);
        if (modulesToBuild.isEmpty()) {
            System.out.println("✅ Aucune modification détectée");
            return;
        }
        
        List<String> allModules = expandWithDependents(modulesToBuild, projectData.dependencies);
        System.out.println("🔄 Modules: " + String.join(", ", allModules));
        
        String command = buildMavenCommand(allModules, projectData);
        System.out.println("\n🔨 " + command);
        
        if (confirmExecution()) {
            executeMaven(command);
            System.out.println("✅ Build réussi!");
        } else {
            System.out.println("⏸️ Annulé");
        }
    }
    
    // ========== PARSING OPTIMISÉ ==========
    
    private Map<String, String> parseArgs(String[] args) {
        Map<String, String> params = new HashMap<>();
        for (int i = 0; i < args.length; i++) {
            if (args[i].startsWith("-")) {
                String key = args[i].substring(1);
                if (Set.of("ForceRebuild", "Init", "UseGit").contains(key)) {
                    params.put(key, "true");
                } else if (i + 1 < args.length && !args[i + 1].startsWith("-")) {
                    params.put(key, args[i + 1]);
                    i++;
                }
            }
        }
        return params;
    }
    
    private String validateRequired(String value, String error) {
        if (value == null || value.trim().isEmpty()) {
            throw new IllegalArgumentException(error);
        }
        return value.trim();
    }
    
    private void validateProjectStructure() {
        Path projectDir = Paths.get(projectPath);
        if (!Files.exists(projectDir)) {
            throw new IllegalArgumentException("Projet inexistant: " + projectPath);
        }
        if (!Files.exists(projectDir.resolve("pom.xml"))) {
            throw new IllegalArgumentException("pom.xml manquant");
        }
    }
    
    // ========== SCAN MODULES PARALLÉLISÉ ==========
    
    private ProjectData scanModules() throws Exception {
        Map<String, String> modules = new ConcurrentHashMap<>();
        Map<String, List<String>> dependencies = new ConcurrentHashMap<>();
        
        // Scan parallèle des POM files
        try (Stream<Path> pomFiles = Files.walk(Paths.get(projectPath))) {
            pomFiles.parallel()
                .filter(path -> "pom.xml".equals(path.getFileName().toString()))
                .filter(this::isNotExcluded)
                .forEach(pom -> {
                    try {
                        ProjectInfo info = readPomInfo(pom);
                        if (info.artifactId != null) {
                            modules.put(info.artifactId, pom.getParent().toString());
                            dependencies.put(info.artifactId, info.dependencies);
                        }
                    } catch (Exception e) {
                        // Ignorer POM invalide
                    }
                });
        }
        
        return new ProjectData(Map.copyOf(modules), Map.copyOf(dependencies));
    }
    
    private ProjectInfo readProjectInfo() throws Exception {
        return readPomInfo(Paths.get(projectPath, "pom.xml"));
    }
    
    private ProjectInfo readPomInfo(Path pomPath) throws Exception {
        Document doc = xmlParser.parse(pomPath.toFile());
        doc.getDocumentElement().normalize();
        
        String artifactId = getFirstElementText(doc, "artifactId");
        String version = getFirstElementText(doc, "version");
        
        // Extraction optimisée des dépendances
        List<String> deps = new ArrayList<>();
        NodeList dependencyNodes = doc.getElementsByTagName("dependency");
        for (int i = 0; i < dependencyNodes.getLength(); i++) {
            Element element = (Element) dependencyNodes.item(i);
            String depArtifactId = getDirectChildText(element, "artifactId");
            if (depArtifactId != null) {
                deps.add(depArtifactId);
            }
        }
        
        return new ProjectInfo(artifactId, version, deps);
    }
    
    private String getFirstElementText(Document doc, String tagName) {
        NodeList nodes = doc.getElementsByTagName(tagName);
        return nodes.getLength() > 0 ? nodes.item(0).getTextContent().trim() : null;
    }
    
    private String getDirectChildText(Element parent, String tagName) {
        NodeList children = parent.getChildNodes();
        for (int i = 0; i < children.getLength(); i++) {
            org.w3c.dom.Node child = children.item(i);
            if (tagName.equals(child.getNodeName())) {
                return child.getTextContent().trim();
            }
        }
        return null;
    }
    
    // ========== HASHING OPTIMISÉ ==========
    
    private String computeModuleHash(String modulePath) throws Exception {
        try (Stream<Path> files = Files.walk(Paths.get(modulePath))) {
            String[] sortedFiles = files.parallel()
                .filter(Files::isRegularFile)
                .filter(this::isHashableFile)
                .filter(this::isNotExcluded)
                .map(Path::toString)
                .sorted()
                .toArray(String[]::new);
            
            if (sortedFiles.length == 0) return "EMPTY";
            
            // Hash parallèle avec combine
            return Arrays.stream(sortedFiles)
                .parallel()
                .map(this::computeFileHash)
                .reduce("", this::combineHashes);
        }
    }
    
    private String computeFileHash(String filePath) {
        try (FileInputStream fis = new FileInputStream(filePath);
             BufferedInputStream bis = new BufferedInputStream(fis, BUFFER_SIZE)) {
            
            MessageDigest localHasher = MessageDigest.getInstance(HASH_ALGORITHM);
            byte[] buffer = new byte[BUFFER_SIZE];
            int bytesRead;
            while ((bytesRead = bis.read(buffer)) != -1) {
                localHasher.update(buffer, 0, bytesRead);
            }
            return bytesToHex(localHasher.digest());
        } catch (Exception e) {
            return "ERROR";
        }
    }
    
    private String combineHashes(String hash1, String hash2) {
        try {
            MessageDigest localHasher = MessageDigest.getInstance(HASH_ALGORITHM);
            localHasher.update(hash1.getBytes());
            localHasher.update(hash2.getBytes());
            return bytesToHex(localHasher.digest());
        } catch (Exception e) {
            return hash1 + hash2; // Fallback
        }
    }
    
    private String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }
    
    // ========== FILTRES OPTIMISÉS ==========
    
    private boolean isHashableFile(Path path) {
        String filename = path.getFileName().toString();
        int dotIndex = filename.lastIndexOf('.');
        return dotIndex > 0 && EXTENSIONS_TO_HASH.contains(filename.substring(dotIndex + 1));
    }
    
    private boolean isNotExcluded(Path path) {
        String pathStr = path.toString();
        return EXCLUSIONS.stream().noneMatch(pathStr::contains);
    }
    
    // ========== DÉTECTION CHANGEMENTS ==========
    
    private List<String> determineModulesToBuild(ProjectData projectData) throws Exception {
        if (specificModule != null && !specificModule.isEmpty()) {
            return validateSpecifiedModules(projectData.modules);
        }
        
        if (useGit) {
            List<String> gitChanges = detectGitChanges(projectData.modules);
            if (gitChanges != null) {
                return forceRebuild && gitChanges.isEmpty() 
                    ? new ArrayList<>(projectData.modules.keySet()) 
                    : gitChanges;
            }
            System.out.println("⚠️ Git indisponible, utilisation du cache");
        }
        
        return detectHashChanges(projectData.modules);
    }
    
    private List<String> validateSpecifiedModules(Map<String, String> modules) {
        List<String> specified = Arrays.asList(specificModule.split(","));
        for (String mod : specified) {
            String trimmed = mod.trim();
            if (!modules.containsKey(trimmed)) {
                throw new IllegalArgumentException("Module '" + trimmed + "' inexistant\n💡 Disponibles: " + 
                    String.join(", ", modules.keySet()));
            }
        }
        
        List<String> result = new ArrayList<>();
        for (String mod : specified) {
            result.add(mod.trim());
        }
        return result;
    }
    
    private List<String> detectHashChanges(Map<String, String> modules) throws Exception {
        Map<String, String> oldHashes = loadCachedHashes();
        List<String> modifiedModules = new ArrayList<>();
        Map<String, String> newHashes = new HashMap<>();
        
        // Calcul parallèle des hashes
        modules.entrySet().parallelStream().forEach(entry -> {
            try {
                String hash = computeModuleHash(entry.getValue());
                synchronized (newHashes) {
                    newHashes.put(entry.getKey(), hash);
                }
                if (forceRebuild || !hash.equals(oldHashes.get(entry.getKey()))) {
                    synchronized (modifiedModules) {
                        modifiedModules.add(entry.getKey());
                    }
                }
            } catch (Exception e) {
                // Marquer comme modifié en cas d'erreur
                synchronized (modifiedModules) {
                    modifiedModules.add(entry.getKey());
                }
            }
        });
        
        saveCachedHashes(newHashes);
        return modifiedModules;
    }
    
    private List<String> detectGitChanges(Map<String, String> modules) {
        try {
            if (!isGitRepository()) return null;
            
            Set<String> changedFiles = new HashSet<>();
            changedFiles.addAll(runGitCommand("ls-files", "--others", "--exclude-standard"));
            changedFiles.addAll(runGitCommand("diff", "--name-only"));
            changedFiles.addAll(runGitCommand("diff", "--name-only", "--staged"));
            
            if (changedFiles.isEmpty()) return List.of();
            
            Path projectDir = Paths.get(projectPath).toAbsolutePath();
            List<String> changedModules = new ArrayList<>();
            
            for (Map.Entry<String, String> entry : modules.entrySet()) {
                Path modulePath = Paths.get(entry.getValue()).toAbsolutePath();
                String relPath = projectDir.relativize(modulePath).toString().replace("\\", "/");
                
                for (String file : changedFiles) {
                    if (file.startsWith(relPath)) {
                        changedModules.add(entry.getKey());
                        break;
                    }
                }
            }
            
            return changedModules;
                
        } catch (Exception e) {
            return null;
        }
    }
    
    private boolean isGitRepository() throws Exception {
        ProcessBuilder pb = new ProcessBuilder("git", "rev-parse", "--is-inside-work-tree");
        pb.directory(new File(projectPath));
        pb.redirectErrorStream(true);
        return pb.start().waitFor() == 0;
    }
    
    private List<String> runGitCommand(String... args) throws Exception {
        List<String> cmd = new ArrayList<>();
        cmd.add("git");
        cmd.addAll(Arrays.asList(args));
        
        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.directory(new File(projectPath));
        Process process = pb.start();
        
        List<String> result = new ArrayList<>();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
            String line;
            while ((line = reader.readLine()) != null) {
                String trimmed = line.trim();
                if (!trimmed.isEmpty()) {
                    result.add(trimmed);
                }
            }
        }
        
        process.waitFor();
        return result;
    }
    
    // ========== GESTION DÉPENDANCES ==========
    
    private List<String> expandWithDependents(List<String> modules, Map<String, List<String>> dependencies) {
        Set<String> result = new HashSet<>(modules);
        for (String module : modules) {
            addDependents(module, dependencies, result);
        }
        List<String> sorted = new ArrayList<>(result);
        Collections.sort(sorted);
        return sorted;
    }
    
    private void addDependents(String module, Map<String, List<String>> dependencies, Set<String> result) {
        for (Map.Entry<String, List<String>> entry : dependencies.entrySet()) {
            if (entry.getValue().contains(module)) {
                String dependent = entry.getKey();
                if (result.add(dependent)) { // Ajoute seulement si pas déjà présent
                    addDependents(dependent, dependencies, result);
                }
            }
        }
    }
    
    // ========== CACHE OPTIMISÉ ==========
    
    private void initializeCache(Map<String, String> modules) throws Exception {
        Map<String, String> cache = new HashMap<>();
        modules.entrySet().parallelStream().forEach(entry -> {
            try {
                String hash = computeModuleHash(entry.getValue());
                synchronized (cache) {
                    cache.put(entry.getKey(), hash);
                }
            } catch (Exception e) {
                // Ignorer en cas d'erreur
            }
        });
        saveCachedHashes(cache);
        System.out.println("✅ Cache initialisé");
    }
    
    private Map<String, String> loadCachedHashes() throws Exception {
        Path cachePath = Paths.get(cacheRoot, CACHE_FILE);
        if (!Files.exists(cachePath)) return Map.of();
        
        Properties props = new Properties();
        try (InputStream fis = Files.newInputStream(cachePath)) {
            props.load(fis);
        }
        
        Map<String, String> result = new HashMap<>();
        for (String key : props.stringPropertyNames()) {
            if (key.startsWith(MODULE_PREFIX)) {
                String moduleName = key.substring(MODULE_PREFIX.length());
                result.put(moduleName, props.getProperty(key));
            }
        }
        return result;
    }
    
    private void saveCachedHashes(Map<String, String> hashes) throws Exception {
        Files.createDirectories(Paths.get(cacheRoot));
        
        Properties props = new Properties();
        for (Map.Entry<String, String> entry : hashes.entrySet()) {
            props.setProperty(MODULE_PREFIX + entry.getKey(), entry.getValue());
        }
        props.setProperty("lastUpdated", LocalDateTime.now().format(DateTimeFormatter.ISO_LOCAL_DATE_TIME));
        
        try (OutputStream fos = Files.newOutputStream(Paths.get(cacheRoot, CACHE_FILE))) {
            props.store(fos, "Maven Smart Builder Cache");
        }
    }
    
    // ========== MAVEN EXECUTION ==========
    
    private String buildMavenCommand(List<String> allModules, ProjectData projectData) throws Exception {
        ProjectInfo rootInfo = readProjectInfo();
        boolean isRootAffected = allModules.contains(rootInfo.artifactId);
        
        if (isRootAffected || allModules.size() == projectData.modules.size()) {
            return "mvn clean install -T 1C";
        }
        
        StringBuilder projectsBuilder = new StringBuilder();
        for (int i = 0; i < allModules.size(); i++) {
            if (i > 0) projectsBuilder.append(",");
            projectsBuilder.append(":").append(allModules.get(i));
        }
        String projects = projectsBuilder.toString();
            
        return "mvn clean install --projects " + projects + " --also-make-dependents -T 1C";
    }
    
    private boolean confirmExecution() {
        System.out.print("❓ Exécuter? (O/N): ");
        try (Scanner scanner = new Scanner(System.in)) {
            return scanner.nextLine().trim().toLowerCase().matches("^[oy].*");
        }
    }
    
    private void executeMaven(String command) throws Exception {
        ProcessBuilder pb = new ProcessBuilder();
        if (System.getProperty("os.name").toLowerCase().contains("windows")) {
            pb.command("cmd", "/c", command);
        } else {
            pb.command("sh", "-c", command);
        }
        pb.directory(new File(projectPath));
        pb.inheritIO();
        
        int exitCode = pb.start().waitFor();
        if (exitCode != 0) {
            throw new RuntimeException("Build échoué (code " + exitCode + ")");
        }
    }
    
    // ========== DATA CLASSES ==========
    
    private static class ProjectData {
        final Map<String, String> modules;
        final Map<String, List<String>> dependencies;
        
        ProjectData(Map<String, String> modules, Map<String, List<String>> dependencies) {
            this.modules = modules;
            this.dependencies = dependencies;
        }
    }
    
    private static class ProjectInfo {
        final String artifactId;
        final String version;
        final List<String> dependencies;
        
        ProjectInfo(String artifactId, String version, List<String> dependencies) {
            this.artifactId = artifactId;
            this.version = version;
            this.dependencies = dependencies;
        }
    }
}
