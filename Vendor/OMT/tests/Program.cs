using System.Net;
using System.Net.Sockets;
using System.Diagnostics;

namespace libomtnet;
internal static class OMTLogging { public static void Write(string message, string category) { } }
internal static class Program {
    private static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    private static void Returned(OMTSocketAsyncPool pool) {
        var clock=Stopwatch.StartNew();
        while (pool.Count!=4 && clock.ElapsedMilliseconds<5000) Thread.Sleep(1);
        Require(pool.Count==4, $"Expected all four reusable slots; got {pool.Count}");
    }
    private static void NullSocketReturnsSlot() {
        using var pool=new OMTSocketAsyncPool(4,1024);
        for (int i=0;i<12;i++) {
            var slot=pool.GetEventArgs(); Require(slot!=null,"Pool exhausted after null socket");
            pool.SendAsync(null,slot); Returned(pool);
        }
    }
    private static void SynchronousFailureReturnsSlot() {
        using var pool=new OMTSocketAsyncPool(4,1024);
        using var closed=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp);
        closed.Dispose();
        for (int i=0;i<12;i++) {
            var slot=pool.GetEventArgs(); Require(slot!=null,"Pool exhausted after failed send");
            bool failed=false;
            try { pool.SendAsync(closed,slot); }
            catch (ObjectDisposedException) { failed=true; }
            catch (SocketException) { failed=true; }
            Require(failed,"A disposed socket unexpectedly accepted data"); Returned(pool);
        }
    }
    private static (Socket client,Socket peer) Pair() {
        using var listener=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp);
        listener.Bind(new IPEndPoint(IPAddress.Loopback,0)); listener.Listen(1);
        var accepted=listener.AcceptAsync();
        var client=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp);
        client.NoDelay=true; client.SendBufferSize=4096;
        client.Connect(listener.LocalEndPoint);
        return (client,accepted.WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult());
    }
    private static void SuccessfulSendRemainsReusable() {
        using var pool=new OMTSocketAsyncPool(4,1024);
        var pair=Pair(); using var client=pair.client; using var peer=pair.peer;
        peer.ReceiveTimeout=5000;
        foreach (int length in new[]{1,131072,17,262144}) {
            byte[] expected=Enumerable.Range(0,length).Select(i=>(byte)(i*17+13)).ToArray();
            var reading=Task.Run(()=>{
                byte[] bytes=new byte[length]; int offset=0;
                while (offset<length) { int n=peer.Receive(bytes,offset,length-offset,SocketFlags.None); Require(n>0,"Premature socket close"); offset+=n; }
                return bytes;
            });
            var slot=pool.GetEventArgs(); Require(slot!=null,"Successful sends exhausted pool");
            pool.Resize(slot,length); expected.CopyTo(slot.Buffer,0); slot.SetBuffer(0,length);
            pool.SendAsync(client,slot);
            byte[] actual=reading.WaitAsync(TimeSpan.FromSeconds(6)).GetAwaiter().GetResult();
            Require(actual.SequenceEqual(expected),"Payload changed or was truncated"); Returned(pool);
        }
    }
    private static void PeerResetReturnsSlot() {
        using var pool=new OMTSocketAsyncPool(4,1024);
        var pair=Pair(); using var client=pair.client; using var peer=pair.peer;
        peer.LingerState=new LingerOption(true,0); peer.Dispose(); Thread.Sleep(20);
        var slot=pool.GetEventArgs(); pool.Resize(slot,262144); slot.SetBuffer(0,262144);
        try { pool.SendAsync(client,slot); } catch (SocketException) { }
        Returned(pool);
    }
    public static int Main() {
        var tests=new (string name,Action run)[]{("null socket returns rented slot",NullSocketReturnsSlot),("synchronous exception returns rented slot",SynchronousFailureReturnsSlot),("small and large successful sends stay reusable",SuccessfulSendRemainsReusable),("peer reset returns rented slot",PeerResetReturnsSlot)};
        int failed=0;
        foreach (var test in tests) {
            try { test.run(); Console.WriteLine("PASS "+test.name); }
            catch (Exception error) { failed++; Console.WriteLine("FAIL "+test.name+": "+error.GetType().Name+" "+error.Message); }
        }
        return failed==0?0:1;
    }
}
