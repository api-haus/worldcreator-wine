using Mono.Cecil;
using Mono.Cecil.Cil;

// Redirects World Creator's forked Veldrid resolution of vkGetMemoryWin32HandleKHR
// from the Vulkan instance proc-addr to the device proc-addr.
//
// Under winevulkan, vkGetInstanceProcAddr("vkGetMemoryWin32HandleKHR") returns NULL
// because that command is device-level; the loader contract permits this. Stock
// Veldrid stores the NULL unguarded into VulkanNative.vkGetMemoryWin32HandleKHR_ptr,
// and the first External buffer creation calls address 0 -> c0000005 execute @ 0x0.
// vkGetDeviceProcAddr returns a valid trampoline for the same command on this stack,
// so this swap makes the resolution succeed and the export path work.
//
// The edit is a single call-operand swap in Veldrid.Vk.VkGraphicsDevice..ctor: the
// `call GetInstanceProcAddr(string)` instruction guarded by the preceding
// `ldstr "vkGetMemoryWin32HandleKHR"` is retargeted to GetDeviceProcAddr(string).
// Both are private instance methods on the same type with signature (string)->IntPtr,
// so the swap is operand-only -- stack shape and surrounding IL are unchanged.

const string TargetTypeName = "Veldrid.Vk.VkGraphicsDevice";
const string FromMethod = "GetInstanceProcAddr";
const string ToMethod = "GetDeviceProcAddr";
const string GuardString = "vkGetMemoryWin32HandleKHR";

if (args.Length != 2)
{
    Console.Error.WriteLine("usage: patch-veldrid <input-Veldrid.dll> <output-Veldrid.dll>");
    return 2;
}

string input = args[0];
string output = args[1];

if (!File.Exists(input))
{
    Console.Error.WriteLine($"error: input not found: {input}");
    return 2;
}

// Cecil resolves referenced assemblies (e.g. the Vulkan binding `vk.dll`) while
// rebuilding metadata for parameter default-value constants on write; point its
// resolver at the install directory where those siblings live.
var resolver = new DefaultAssemblyResolver();
var inputDir = Path.GetDirectoryName(Path.GetFullPath(input));
if (inputDir is not null)
    resolver.AddSearchDirectory(inputDir);

using var asm = AssemblyDefinition.ReadAssembly(input, new ReaderParameters { AssemblyResolver = resolver });
var module = asm.MainModule;

var type = module.GetType(TargetTypeName);
if (type is null)
{
    Console.Error.WriteLine($"error: type {TargetTypeName} not found in {input}");
    return 1;
}

// The (string)->IntPtr resolvers are private instance methods with no generic
// parameters; the generic overloads GetInstanceProcAddr<T>/GetDeviceProcAddr<T>
// share the name and are excluded by the parameter/generic predicate.
static bool IsStringToIntPtr(MethodDefinition m) =>
    !m.HasGenericParameters
    && m.Parameters.Count == 1
    && m.Parameters[0].ParameterType.FullName == "System.String"
    && m.ReturnType.FullName == "System.IntPtr";

var fromDef = type.Methods.SingleOrDefault(m => m.Name == FromMethod && IsStringToIntPtr(m));
var toDef = type.Methods.SingleOrDefault(m => m.Name == ToMethod && IsStringToIntPtr(m));
if (fromDef is null || toDef is null)
{
    Console.Error.WriteLine($"error: could not resolve both resolvers ({FromMethod}/{ToMethod}) with signature (string)->IntPtr");
    return 1;
}

// The faulting resolution lives in VkGraphicsDevice..ctor today, but the only
// thing that pins it unambiguously is the `ldstr "vkGetMemoryWin32HandleKHR"`
// immediately preceding the call. Scan every method body on the type for that
// guarded site rather than pre-selecting a constructor by signature: the type
// has several constructors, and the single string load is the precise anchor.
int patched = 0;
int alreadyTarget = 0;

foreach (var method in type.Methods)
{
    if (!method.HasBody)
        continue;

    var il = method.Body.Instructions;
    for (int i = 1; i < il.Count; i++)
    {
        var ins = il[i];
        if (ins.OpCode != OpCodes.Call || ins.Operand is not MethodReference mref)
            continue;

        bool guarded = il[i - 1].OpCode == OpCodes.Ldstr
            && (il[i - 1].Operand as string) == GuardString;
        if (!guarded)
            continue;

        if (mref.Name == ToMethod && AreSame(mref, toDef))
        {
            alreadyTarget++;
            continue;
        }

        if (mref.Name != FromMethod)
        {
            Console.Error.WriteLine($"error: guarded call in {method.FullName} targets unexpected method {mref.FullName}");
            return 1;
        }

        ins.Operand = toDef;
        patched++;
    }
}

if (alreadyTarget > 0 && patched == 0)
{
    Console.WriteLine($"already patched: {GuardString} resolves via {ToMethod} ({alreadyTarget} site). Writing passthrough copy.");
    asm.Write(output);
    return 0;
}

if (patched == 0)
{
    Console.Error.WriteLine($"error: no guarded {FromMethod}(\"{GuardString}\") call found in {TargetTypeName}..ctor; aborting without write");
    return 1;
}

if (patched != 1)
{
    Console.Error.WriteLine($"error: expected exactly one guarded call site, patched {patched}; aborting without write");
    return 1;
}

asm.Write(output);
Console.WriteLine($"patched {patched} call site: {GuardString} now resolves via {ToMethod}(string) -> vkGetDeviceProcAddr. wrote {output}");
return 0;

static bool AreSame(MethodReference a, MethodDefinition b) =>
    a.Name == b.Name
    && a.DeclaringType.FullName == b.DeclaringType.FullName
    && a.Parameters.Count == b.Parameters.Count;
