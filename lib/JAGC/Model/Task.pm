package JAGC::Model::Task;

use Mojo::Base 'MojoX::Model';
use Mojo::Util qw/encode trim/;
use Mango::BSON ':bson';

sub _validate {
  my ($p, $v) = @_;

  my $hparams = $p->to_hash;
  my @test_fields = grep { /^test_/ } %{$hparams};

  for (@test_fields) {
    $hparams->{$_} =~ s/\r\n/\n/g;
    $hparams->{$_} =~ s/^\n*|\n*$//g;
  }

  my $to_validate = {name => trim($hparams->{name}), description => trim($hparams->{description})};
  $to_validate->{$_} = $hparams->{$_} for @test_fields;

  $v->input($to_validate);
  $v->required('name')->size(1, 50, 'Length of task name must be no more than 50 characters');
  $v->required('description')->size(1, 500, 'Length of description must be no more than 500 characters');
  $v->required($_)->size(1, 100000, 'Length of test must be no more than 100000 characters') for @test_fields;
  $v->enough_tests;

  return $v;
}

sub add {
  my ($self, %args) = @_;
  my $db = $self->app->db;

  my $s = $args{session};
  my $p = $args{params};    # Mojo::Parameters

  my $uid = bson_oid $s->{uid};

  my $v = _validate($p, $args{validation});
  my %res = (validation => $v);

  return %res if ($v->has_error);

  my @tests;
  for my $tin (grep { /^test_\d+_in$/ } @{$p->names}) {
    (my $tout = $tin) =~ s/in/out/;
    my $test_in  = $v->param($tin);
    my $test_out = $v->param($tout);
    my $test     = bson_doc(
      _id => bson_oid,
      in  => bson_bin(encode 'UTF-8', $test_in),
      out => bson_bin(encode 'UTF-8', $test_out),
      ts  => bson_time
    );
    push @tests, $test;
  }

  my $q = bson_doc(
    name  => $v->param('name'),
    desc  => $v->param('description'),
    owner => bson_doc(uid => $uid, login => $s->{login}, pic => $s->{pic}),
    stat  => bson_doc(all => 0, ok => 0),
    ts    => bson_time,
    tests => \@tests
  );

  $q->{con} = bson_oid($args{con}) if $args{con};
  my $oid = eval { $db->c('task')->insert($q) };

  if ($@) {
    $res{err} = "Error while insert task: $@";
    return %res;
  }

  $res{tid} = bson_oid $oid;
  return %res;
}

sub view {
  my ($self, %args) = @_;
  my $db = $self->app->db;
  my $s  = $args{session};

  my $id   = bson_oid $args{tid};
  my $task = $db->c('task')->find_one($id);
  return (err => "Error while find_one task with $id: $!") unless $task;
  my $lang = $db->c('language')->find({})->fields({name => 1, _id => 0})->all;

  my %res = (task => $task, languages => [map { $_->{name} } @$lang]);

  my $col = $db->c('solution');
  my $solutions;
  if ($args{s}) {
    $solutions = $col->find(bson_doc('task.tid' => $id, s => 'finished'))->fields({task => 0})
      ->sort(bson_doc(size => 1, ts => 1))->limit(20)->all;
  } else {
    $solutions = $col->find(bson_doc('task.tid' => $id, s => {'$in' => [qw/incorrect timeout error/]}))
      ->fields({task => 0})->sort(bson_doc(ts => 1))->limit(20)->all;
  }

  my $comments_count =
    $db->c('comment')->find(bson_doc(type => 'task', tid => $id, del => bson_false))->count;

  my $solution_comments = $db->c('comment')->aggregate([
      {'$match' => bson_doc(tid => $id, type => 'solution', del => bson_false)},
      {'$group' => bson_doc(_id => '$sid', count => {'$sum' => 1})}
    ]
  )->all;

  my %solution_comments;
  map { $solution_comments{$_->{_id}} = $_->{count} } @$solution_comments;

  my $notice;

  if (my $uid = $s->{uid}) {
    $notice = $db->c('notification')->find_one(bson_doc(uid => bson_oid($uid), tid => $id), {for => 1});
  }

  return (
    %res,
    solutions         => $solutions,
    comments_count    => $comments_count,
    solution_comments => \%solution_comments,
    notice            => $notice,
  );
}

1;
