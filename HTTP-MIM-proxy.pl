#!/usr/bin/perl -w
# ============================================================================
# HTTP Man In The Middle Logging proxy
# ------------------------------------
# Binds to the proxy server and pass through all the requests.
# Saves all of requests & files (by default) and keep extended log file on the operations done.
#
#
# Relies on core distribution (no dependencies), designed to be multi-treaded with
# smallest memory and CPU usage possible.
#
# Tested & works under Perl 5.8, 5.10, 5.12.
#
# Copyright 2010 Alexander Potemkin (alexander@10bees.com)
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#============================================================================

use strict;
use IO::Socket::INET;
use IO::Select;
use Fcntl;
use POSIX qw (:sys_wait_h _exit);
no utf8;

#Settings
my %proxy = (host => '1.2.3.4', port => '8080'); #actual proxy server, might be local.
my $localPortToBind = 2101; #local machine port number, where script mimicry to be a proxy.
my $logFileFQName = 'MIM-Proxy.log'; #log file name - place for all operations recording.
my $storageFQPath = 'storage'; #directory name, where all files matched are saved.
#match file name & extension, check done by applying regexp on the link
#To store most wide spread multimedia files, use the following:
my $filesToDump = '.*';
#do not preserve the original file names to ensure there is no naming conflict
my $doPreserveFileNames => 0;
#duplicate logs on the console or not
my $doConsoleLogging => 1;

#used to keep files handlers
my %streamSaverHandlers;
#script lock file name, to ensure there is only one instance is running at the moment of time
my $referenceFileName = "_http_mim_is_running";

if (-e $referenceFileName) {die "Another instance is running / crashed (please, check '$referenceFileName' lock file).\n";}
if (!-e $storageFQPath) {mkdir $storageFQPath or die "Storage directory was not found, can not be created either $!.\n";}

#Logging
sysopen(logHandler, $logFileFQName, O_WRONLY | O_CREAT) or die "Can't open log file $!\n";

#Reference file
sysopen(tmpHandler, $referenceFileName, O_WRONLY | O_CREAT | O_TRUNC) or die "Can't create lock file $!\n";
syswrite(tmpHandler, "PID: ".$$);
close(tmpHandler);

$| = 1; #flash the content on the console, as it goes
$SIG{CHLD} = 'IGNORE'; #no zombies

my $forkedChild = 1; #0 is for children / 1 is for unforked server

my %allOfTheChildren = () if ($forkedChild == 1); #first time init

#opening local port
my $serverSocket = IO::Socket::INET->new(
                    LocalPort => $localPortToBind,
                    Type => SOCK_STREAM,
                    Reuse => 1,
                    Listen => 20) or die "Can't open server socket: $!";

#a primitive logging
sub logMessage {syswrite(logHandler, $_[0]."\n"); print STDOUT $_[0]."\n";}

#Procedure executed every time process have something to store
#Files are transfered in a parts, so there are three cases when the procedure might be executed:
#- first call: new file transfer initiated - creating and opening file handler, store the reference;
#- second call: file stream continuation, append file content;
#- final call: executed with new arguments (one stream - one file) - new file transfer initiated.
sub storeStream ($$$) {
    my ($threadId, $url, $content) = ($_[0], $_[1], $_[2]);
    
    #keeps new file pointer
    my $fileHandler;    
    
    #first call (with file name on it)
    if (defined($url) && $url) {
        
        #skip files we don't care about
        if ($url !~ m/$filesToDump/i) {
            $streamSaverHandlers{$threadId} = undef;
        }
    }
    
    #Lookup / create a file handler
    
    #Closing old handler, opening a new one in case if it's a new file
    close(delete($streamSaverHandlers{$threadId}))
        if ($url && defined($streamSaverHandlers{$threadId}) && exists($streamSaverHandlers{$threadId}));
    
    #Take the handler from the hash
    if (exists($streamSaverHandlers{$threadId}) && defined($streamSaverHandlers{$threadId})) {
        die "Incorrect (hashed) handler, can't proceed."
            unless ref ($fileHandler = $streamSaverHandlers{$threadId}) eq 'GLOB';
    
    #File name didn't match the regexp specified - do nothing
    } elsif (exists($streamSaverHandlers{$threadId}) && !defined($streamSaverHandlers{$threadId})) {
        return;
    
    #New file - create a handler & add it to the hash
    } elsif (defined($url) && $url) {
        
        $url =~ m|(?:.*)/(.*)|; #file name
        my $newName = $1;
        $newName =~ s/[\\\/\*?:"<>;%&.=|]/_/g; #remove "invalid" symbols from the filesystem perspective
	$newName = substr $newName, 0, 150; #be sure it is not more than 200 symbols long
	$newName = $storageFQPath.'/'.$newName; #relative to full-qualified name
        
        #if there is a chance to override an existent file, make a backup first
        if ($doPreserveFileNames) {
            rename $newName, $newName.'_backupAsOf'.time()
                if (-e $newName);
                
        #preserving file extension, if any
        } else {
            
            if ($url =~ m|(?:.*)/(?:.*)\.(\w{1,3})|) { #extension found
                $newName = $newName.'_'.$$.'_'.time().".$1";
            } else {
                $newName = $newName.'_'.$$.'_'.time(); #no extension
            }
            
        }
        
        #Failed to create file (no write access, disk is full, whatever)
        die "Can't create '$newName' file for writing: $!"
            unless open($fileHandler, ">$newName");
        
        #no encodings
        binmode($fileHandler);
        
        #save handler reference
        $streamSaverHandlers{$threadId} = $fileHandler;
        
        logMessage "$$ starts catching '$newName' (source: '$url').";
      
    
    #Should not be there, make a complete dump
    } else {
        die "$$ @ ".(caller(1))[3].' - call made with no file name specified, neither provided a handler opened.';
    }
    
    #write things down
    print $fileHandler $content;
}

#clean up stuff
sub closeStreamWriter ($) {
    close (delete($streamSaverHandlers{$_[0]})) if exists($streamSaverHandlers{$_[0]});
}

#Gentle handle of the interruption call
sub onExit {
    if ($forkedChild) {
        print "Server caught close signal.";
        close($serverSocket);
        logMessage "Server leaving...\n";
        close(logHandler);
        rename ($logFileFQName, $logFileFQName.'_'.time());
        unlink($referenceFileName);
    }    
}

#Server's graceful cleanup.
#Doesn't work on Windows, consider using a .bat crutch unstead:
#-----***-----
#@echo off
#perl -w forwarder.pl
#del _forwarder_is_running
#move mim-proxy.log storage\mim-proxy.previous.log
#-----***-----

$SIG{INT} = \&onExit;
#$SIG{BREAK} = \&onExit;

logMessage "Server bind on port $localPortToBind done.";

#serving loop
while (my $clientSocket = $serverSocket->opened()?$serverSocket->accept():undef) {

    #server's job
    if ($forkedChild) {
        die "Can't fork: $!" unless defined ($forkedChild = fork());
    }
    
    #Forked child proccess
    if ($forkedChild == 0) {
        
        logMessage "$$ serving request from port ".$clientSocket->peerport.".";
        
        $serverSocket->close; #release original connection
        
        #Setting up a new proxy server connection for that child
        my $proxyConnectSocket = IO::Socket::INET->new(
                            PeerAddr => $proxy{host},
                            PeerPort => $proxy{port},
                            Proto => 'tcp',
                            Type => SOCK_STREAM) or die "Couldn't connect to the proxy! $!";
            
        my ($bytesRead, $socketReader, $bytesContent);
        my (%forwardedContent);
        
        #sockets switcher
        my $select = IO::Select->new($clientSocket, $proxyConnectSocket);
        
	#do the bytes forward job
        LOOP:
        while (1) {
            
            foreach $socketReader ($select->can_read(10)) {
                
                #network bytes I/O
                last LOOP unless (defined($bytesRead = sysread($socketReader, $bytesContent, 4096)));
                last LOOP if ($bytesRead == 0);
                last LOOP unless (defined(syswrite(((fileno($socketReader) == fileno($clientSocket))? $proxyConnectSocket : $clientSocket ), $bytesContent, $bytesRead)));
                
                #forwarded bytes content
                %forwardedContent = (isClient => (fileno($socketReader) == fileno($clientSocket)), content => $bytesContent);
            
                #Client's request
                if ($forwardedContent{isClient}) {
                    
                    #HTTP level information
                    my ($httpMethod, $targetURL, $httpVersion) = $forwardedContent{content} =~ /^(\w+) +(\S+) +(\S+)/;
                    
                    #Looks like a regular request (with text on it) 
                    if ($httpMethod && $targetURL) {
                    
                        #strip headers, dump request content & leave log record
                        my $content = substr($forwardedContent{content}, index($forwardedContent{content}, "\r\n\r\n") + 4);
                        storeStream($$, $targetURL, $content);
                        logMessage "$$ < $httpMethod '$targetURL'";
                    
                    #Binary data
                    } else {
                        #nothing to strip - pure binary data: make a dump, leave a log record on it
                        storeStream($$, undef, $forwardedContent{content});
                        logMessage "$$ < binary data send";
                    }
                    
                #Server answer
                } else {
                    
                    #HTTP variables
                    my ($protocol, $protoVersion, $answerCode, $answerDescription) =
                        $forwardedContent{content} =~ /^(.*)\/(\d.\d)\W+(\d+)\W+(.*)/i;
                        
                    #server reply with a text based information on it
                    if ($answerCode && $protocol =~ m/(?:.{0,5})HTTP(?:.{0,5})/i) {
                        
                        $answerDescription =~ s/^\s+|\s+$//g; #no extra new line symbols
                        
                        #strip headers, dump request content & leave log record
                        my $content = substr($forwardedContent{content}, index($forwardedContent{content}, "\r\n\r\n") + 4);
                        storeStream($$, undef, $content);
                        logMessage "$$ > $answerCode [$answerDescription]";
                    
                    #continuation of the HTTP traffic
                    } else {
                        #pure binary data, save it on the disk
			#(no loggin to avoid logs flood for big files)
                        storeStream($$, undef, $forwardedContent{content});
                    }
                }
            }
        }
        
        #sockets cleanup
        $proxyConnectSocket->close;
        $clientSocket->close;
        
    #Dispatching server part of the script
    } else {
        
        #child just dup()-ed
        $clientSocket->close;
        
        #keep track of the children alive...
        $allOfTheChildren{$forkedChild} = 1;
        
        #... and killed
        my @childsKilled = ();
        
        #new child created, time to walk through "old" children and check them
        while (my($childId, $childStatus) = each(%allOfTheChildren)) {
            
            #non-blocking request
            $childStatus = waitpid($childId, WNOHANG);
            
            #idle baby, got you
            if ($childStatus == -1) {
                #store it's number, kill and clean up after
                my $killedId = kill ('TERM', $childId);
                closeStreamWriter($killedId);
                delete($allOfTheChildren{$childId});
                push (@childsKilled, $childId);
            }
        }
        
        logMessage "+$$: killed ".join(', ', @childsKilled)." idle children." if @childsKilled; #no empty entries
    }
}
