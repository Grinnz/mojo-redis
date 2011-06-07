package MojoX::Redis;

use strict;
use warnings;

our $VERSION = 0.8;
use base 'Mojo::Base';

use Mojo::IOLoop;
use List::Util   ();
use Mojo::Util   ();
use Scalar::Util ();
require Carp;

__PACKAGE__->attr(server   => '127.0.0.1:6379');
__PACKAGE__->attr(ioloop   => sub { Mojo::IOLoop->singleton });
__PACKAGE__->attr(error    => undef);
__PACKAGE__->attr(timeout  => 300);
__PACKAGE__->attr(encoding => 'UTF-8');
__PACKAGE__->attr(
    on_error => sub {
        sub {
            my $redis = shift;
            warn "Redis error: ", $redis->error, "\n";
          }
    }
);

__PACKAGE__->attr(
    protocol_redis => sub {
        require Protocol::Redis;
        "Protocol::Redis";
    }
);

our @COMMANDS = qw/
  append auth bgrewriteaof bgsave blpop brpop brpoplpush config_get config_set
  config_resetstat dbsize debug_object debug_segfault decr decrby del discard
  echo exec exists expire expireat flushall flushdb get getbit getrange getset
  hdel hexists hget hgetall hincrby hkeys hlen hmget hmset hset hsetnx hvals
  incr incrby info keys lastsave lindex linsert llen lpop lpush lpushx lrange
  lrem lset ltrim mget monitor move mset msetnx multi persist ping psubscribe
  publish punsubscribe quit randomkey rename renamenx rpop rpoplpush rpush
  rpushx sadd save scard sdiff sdiffstore select set setbit setex setnx
  setrange shutdown sinter sinterstore sismember slaveof smembers smove sort
  spop srandmember srem strlen subscribe sunion sunionstore sync ttl type
  unsubscribe unwatch watch zadd zcard zcount zincrby zinterstore zrange
  zrangebyscore zrank zrem zremrangebyrank zremrangebyscore zrevrange
  zrevrangebyscore zrevrank zscore zunionstore
  /;

sub AUTOLOAD {
    my ($package, $cmd) = our $AUTOLOAD =~ /^([\w\:]+)\:\:(\w+)$/;

    Carp::croak(qq|Can't locate object method "$cmd" via "$package"|)
      unless List::Util::first { $_ eq $cmd } @COMMANDS;

    my $self = shift;

    my $args = [@_];
    my $cb   = $args->[-1];
    if (ref $cb ne 'CODE') {
        $cb = undef;
    }
    else {
        pop @$args;
    }

    $self->execute($cmd, $args, $cb);
}

sub DESTROY {
    my $self = shift;

    # Loop
    return unless my $loop = $self->ioloop;

    # Cleanup connection
    $loop->drop($self->{_connection})
      if $self->{_connection};
}

sub connect {
    my $self = shift;

    # drop old connection
    if ($self->connected) {
        $self->ioloop->drop($self->{_connection});
    }

    $self->server =~ m{^([^:]+)(:(\d+))?};
    my $address = $1;
    my $port = $3 || 6379;

    Scalar::Util::weaken $self;

    $self->{_protocol} = $self->_create_protocol;

    # connect
    $self->{_connecting} = 1;
    $self->{_connection} = $self->ioloop->connect(
        {   address    => $address,
            port       => $port,
            on_connect => sub { $self->_on_connect(@_) },
            on_read    => sub { $self->_on_read(@_) },
            on_error   => sub { $self->_on_error(@_) },
            on_close   => sub { $self->_on_hup(@_) },
        }
    );

    return $self;
}

sub connected {
    my $self = shift;

    return $self->{_connection};
}

sub execute {
    my ($self, $command, $args, $cb) = @_;

    if (!$cb && ref $args eq 'CODE') {
        $cb   = $args;
        $args = [];
    }
    elsif (!ref $args) {
        $args = [$args];
    }

    unshift @$args, uc $command;

    my $mqueue = $self->{_message_queue} ||= [];
    my $cqueue = $self->{_cb_queue}      ||= [];


    push @$mqueue, $args;
    push @$cqueue, $cb;

    $self->connect unless $self->{_connection};
    $self->_send_next_message;

    return $self;
}

sub start {
    my ($self) = @_;

    $self->ioloop->start;
    return $self;
}

sub stop {
    my ($self) = @_;

    $self->ioloop->stop;
    return $self;
}

sub _create_protocol {
    my $self = shift;

    my $protocol = $self->protocol_redis->new(
        api        => 1,
        on_message => sub {
            my ($parser, $command) = @_;
            $self->_return_command_data($command);
        }
    );

    Carp::croak(q/Protocol::Redis implementation doesn't support APIv1/)
      unless $protocol;

    $protocol;
}

sub _send_next_message {
    my ($self) = @_;

    if ((my $c = $self->{_connection}) && !$self->{_connecting}) {
        while (my $args = shift @{$self->{_message_queue}}) {
            my $cmd_arg = [];
            my $cmd = {type => '*', data => $cmd_arg};
            foreach my $token (@$args) {
                Mojo::Util::encode($self->encoding, $token)
                  if $self->encoding;
                push @$cmd_arg, {type => '$', data => $token};
            }
            my $message = $self->{_protocol}->encode($cmd);

            $self->ioloop->write($c, $message);
        }
    }
}

sub _on_connect {
    my ($self, $ioloop, $id) = @_;
    delete $self->{_connecting};

    $ioloop->connection_timeout($id => $self->timeout);

    $self->_send_next_message;
}

sub _reencode_message {
    my ($self, $message) = @_;

    my ($type, $data) = @{$message}{'type', 'data'};
    if ($type eq '-') {
        $self->error($data);
        $self->on_error->($self);
        return;
    }
    elsif ($type ne '*') {
        return [$data];
    }
    else {
        my $reencoded_data = [];
        foreach my $item (@$data) {
            my $message = $self->_reencode_message($item);
            push @$reencoded_data, $message;
        }
        return $reencoded_data;
    }
}

sub _return_command_data {
    my ($self, $message) = @_;

    my $data = $self->_reencode_message($message);

    my $cb = shift @{$self->{_cb_queue}};
    if ($cb) {

        # Decode data
        if ($self->encoding && $data) {
            Mojo::Util::decode($self->encoding, $_) for @$data;
        }

        $cb->($self, $data);
    }

    # Reset error after callback dispatching
    $self->error(undef);
}

sub _on_error {
    my ($self, $ioloop, $id, $error) = @_;

    $self->error($error);
    $self->_inform_queue;

    $self->on_error->($self);

    $ioloop->drop($id);
}

sub _on_hup {
    my ($self, $ioloop, $id) = @_;

    $self->{error} ||= 'disconnected';
    $self->_inform_queue;

    delete $self->{_message_queue};

    delete $self->{_connecting};
    delete $self->{_connection};
}

sub _inform_queue {
    my ($self) = @_;

    for my $cb (@{$self->{_cb_queue}}) {
        $cb->($self) if $cb;
    }
    $self->{_queue} = [];
}

sub _on_read {
    my ($self, $ioloop, $id, $chunk) = @_;

    $self->{_protocol}->parse($chunk);
}

1;
__END__

=head1 NAME

MojoX::Redis - asynchronous Redis client for L<Mojolicious>.

=head1 SYNOPSIS

    use MojoX::Redis;

    my $redis = MojoX::Redis->new(server => '127.0.0.1:6379');

    # Execute some commands
    $redis->ping(
        sub {
            my ($redis, $res) = @_;

            if ($res) {
                print "Got result: ", $res->[0], "\n";
            }
            else {
                print "Error: ", $redis->error, "\n";
            }
      })

      # Work with keys
      ->set(key => 'value')

      ->get(key => sub {
          my ($redis, $res) = @_;

          print "Value of ' key ' is $res->[0]\n";
      })


      # Cleanup connection
      ->quit(sub { shift->stop })->start;

=head1 DESCRIPTION

L<MojoX::Redis> is an asynchronous client to Redis for Mojo.

=head1 ATTRIBUTES

L<MojoX::Redis> implements the following attributes.

=head2 C<server>

    my $server = $redis->server;
    $redis     = $redis->server('127.0.0.1:6379');

C<Redis> server connection string, defaults to '127.0.0.1:6379'.

=head2 C<ioloop>

    my $ioloop = $redis->ioloop;
    $redis     = $redis->ioloop(Mojo::IOLoop->new);

Loop object to use for io operations, by default a L<Mojo::IOLoop> singleton
object will be used.

=head2 C<timeout>

    my $timeout = $redis->timeout;
    $redis      = $redis->timeout(100);

Maximum amount of time in seconds a connection can be inactive before being
dropped, defaults to C<300>.

=head2 C<encoding>

    my $encoding = $redis->encoding;
    $redis       = $redis->encoding('UTF-8');

Encoding used for stored data, defaults to C<UTF-8>.

=head2 C<protocol_redis>

    use Protocol::Redis;
    $redis->protocol_redis("Protocol::Redis");

L<Protocol::Redis> implementation' constructor for parsing. By default
L<Protocol::Redis> will be used. Parser library must support
L<APIv1|Protocol::Redis/APIv1>.

=head1 METHODS

L<MojoX::Redis> supports Redis' methods.

    $redis->set(key => 'value);
    $redis->get(key => sub { ... });

For more details take a look at C<execute> method.

Also L<MojoX::Redis> implements the following ones.

=head2 C<connect>

    $redis = $redis->connect;

Connect to C<Redis> server.

=head2 C<execute>

    $redis = $redis->execute("ping" => sub{
        my ($redis, $result) = @_;

        # Process result
    });
    $redis->execute(lrange => ["test", 0, -1] => sub {...});
    $redis->execute(set => [test => "test_ok"]);

Execute specified command on C<Redis> server. If error occured during
request $result will be set to undef, error string can be obtained with 
$redis->error.

=head2 C<error>

    $redis->execute("ping" => sub {
        my ($redis, $result) = @_;
        die $redis->error unless defined $result;
    }

Returns error occured during command execution.
Note that this method returns error code just from current command and
can be used just in callback.

=head2 C<on_error>

    $redis->on_error(sub{
        my $redis = shift;
        warn 'Redis error ', $redis->error, "\n";
    });

Executes if error occured. Called before commands callbacks.

=head2 C<start>

    $redis->start;

Starts IOLoop. Shortcut for $redis->ioloop->start;

=head1 SEE ALSO

L<Protocol::Redis>, L<Mojolicious>, L<Mojo::IOLoop>

=head1 SUPPORT

=head2 IRC

    #ru.pm on irc.perl.org
    
=head1 DEVELOPMENT

=head2 Repository

    https://github.com/und3f/mojox-redis

=head1 AUTHOR

Sergey Zasenko, C<undef@cpan.org>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010-2011, Sergey Zasenko

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
