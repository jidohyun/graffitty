"""Deliberately forwards only bytes, like ssh -L for a Unix socket."""
import socket
import sys
import threading
listener=socket.socket(socket.AF_UNIX)
listener.bind(sys.argv[1]);listener.listen()
def connection(client):
    remote=socket.socket(socket.AF_UNIX);remote.connect(sys.argv[2])
    def copy(source,destination):
        try:
            while data:=source.recv(65536):destination.sendall(data)
        except OSError:pass
        finally:
            try:destination.shutdown(socket.SHUT_WR)
            except OSError:pass
    thread=threading.Thread(target=copy,args=(client,remote),daemon=True);thread.start()
    copy(remote,client);thread.join();client.close();remote.close()
while True:
    client,_=listener.accept();threading.Thread(target=connection,args=(client,),daemon=True).start()
