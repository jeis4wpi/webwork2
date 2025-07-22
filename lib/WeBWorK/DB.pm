package WeBWorK::DB;
use Mojo::Base -strict;

=head1 NAME

WeBWorK::DB - interface with the WeBWorK databases.

=head1 SYNOPSIS

 my $db = WeBWorK::DB->new($ce);

 my @userIDs = $db->listUsers();
 my $Sam = $db->{user}->{record}->new();

 $Sam->user_id("sammy");
 $Sam->first_name("Sam");
 $Sam->last_name("Hathaway");
 # etc.

 $db->addUser($User);
 my $Dennis = $db->getUser("dennis");
 $Dennis->status("C");
 $db->putUser->($Dennis);

 $db->deleteUser("sammy");

=head1 DESCRIPTION

WeBWorK::DB provides a database interface.  Access and modification functions
are provided for each logical table used by the webwork system. The particular
schema, record class, and additional parameters are specified by the hash return
by the C<DBLayout::databaseLayout> method.

=head1 ARCHITECTURE

The new database system uses a three-tier architecture to insulate each layer
from the adjacent layers.

=head2 Top Layer: DB

The top layer of the architecture is the DB module. It provides the methods
listed below, and uses schema modules (via tables) to implement those methods.

         / new* list* exists* add* get* get*s put* delete* \          <- api
 +------------------------------------------------------------------+
 |                                DB                                |
 +------------------------------------------------------------------+
  \ password permission key user set set_user problem problem_user /  <- tables

=head2 Middle Layer: Schemas

The middle layer of the architecture is provided by one or more schema modules.
They are called "schema" modules because they control the structure of the data
for a table.

The schema modules provide an API that matches the requirements of the DB
layer, on a per-table basis.

=head2 Bottom Layer: Database

The C<Database> module implements a DBI connection handle. It provides physical
access to the database.

=head2 Record Types

In the database layout, each table is assigned a record class, used for passing
complete records to and from the database. The default record classes are
subclasses of the WeBWorK::DB::Record class, and are named as follows: User,
Password, PermissionLevel, Key, Set, UserSet, Problem, UserProblem. In the
following documentation, a reference to the record class for a table means the
record class currently defined for that table in the database layout.

=cut

use Carp;
use Data::Dumper;
use Scalar::Util   qw(blessed);
use HTML::Entities qw(encode_entities);
use Mojo::JSON     qw(encode_json decode_json);

use WeBWorK::DB::Database;
use WeBWorK::DB::Schema;
use WeBWorK::DB::Layout qw(databaseLayout);
use WeBWorK::DB::Utils  qw(make_vsetID grok_vsetID grok_setID_from_vsetID_sql grok_versionID_from_vsetID_sql);
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use);

# How these exceptions should be used:
#
# * RecordExists is thrown when an INSERT fails because the record being
# inserted already exists. This exception is thrown by the database error
# handler and should not be thrown here or anywhere else.
#
# * RecordNotFound should be thrown if an UPDATE is attempted and there was no
# existing record to update. These exceptions should only be thrown by this
# file.
#
# * DependencyNotFound should be thrown when a record in another table does not
# exist that should exist for a record in the current table to be inserted (e.g.
# password depends on user). These exceptions should only be thrown by this
# file.
#
# * TableMissing is thrown if a table in the database layout is missing. This
# exception is thrown by the database error handler and should not be thrown
# here or anywhere else.

use Exception::Class (
	'WeBWorK::DB::Ex' => {
		description => 'unknown database error',
	},
	'WeBWorK::DB::Ex::RecordExists' => {
		isa         => 'WeBWorK::DB::Ex',
		description => "record exists"
	},
	'WeBWorK::DB::Ex::RecordNotFound' => {
		isa         => 'WeBWorK::DB::Ex',
		description => "record not found"
	},
	'WeBWorK::DB::Ex::DependencyNotFound' => {
		isa => 'WeBWorK::DB::Ex::RecordNotFound',
	},
	'WeBWorK::DB::Ex::TableMissing' => {
		isa         => 'WeBWorK::DB::Ex',
		description => "missing table",
	},
);

=head1 CONSTRUCTOR

    my $db = WeBWorK::DB->new($ce)

The C<new> method creates a DB object, connects to the database via the
C<Database> module, and brings up the underlying schema structure according to
the hash referenced in the L<database layout|WeBWorK::DB::Layout>.  A course
environment object is the only required argument (as it is used to construct the
database layout).

For each table defined in the database layout, C<new> loads the record and
schema modules.

=cut

sub new {
	my ($invocant, $ce) = @_;
	my $self = bless {}, ref($invocant) || $invocant;

	my $dbh = eval {
		WeBWorK::DB::Database->new(
			$ce->{database_dsn},
			$ce->{database_username},
			$ce->{database_password},
			engine         => $ce->{database_storage_engine},
			character_set  => $ce->{database_character_set},
			debug          => $ce->{database_debug},
			mysql_path     => $ce->{externalPrograms}{mysql},
			mysqldump_path => $ce->{externalPrograms}{mysqldump}
		);
	};
	croak "Unable to establish a connection to the database: $@" if $@;

	my $dbLayout = databaseLayout($ce->{courseName});

	# Load the modules required to handle each table.
	for my $table (keys %$dbLayout) {
		$self->init_table($dbLayout, $table, $dbh);
	}

	return $self;
}

sub init_table {
	my ($self, $dbLayout, $table, $dbh) = @_;

	if (exists $self->{$table}) {
		if (defined $self->{$table}) {
			return;
		} else {
			die "loop in dbLayout table dependencies involving table '$table'\n";
		}
	}

	my $layout        = $dbLayout->{$table};
	my $record        = $layout->{record};
	my $schema        = $layout->{schema};
	my $depend        = $layout->{depend};
	my $params        = $layout->{params};
	my $engine        = $layout->{engine};
	my $character_set = $layout->{character_set};

	# add a key for this table to the self hash, but don't define it yet
	# this for loop detection
	$self->{$table} = undef;

	if ($depend) {
		foreach my $dep (@$depend) {
			$self->init_table($dbLayout, $dep, $dbh);
		}
	}

	runtime_use($record);

	runtime_use($schema);
	my $schemaObject = eval { $schema->new($self, $dbh, $table, $record, $params, $engine, $character_set) };
	croak "error instantiating DB schema $schema for table $table: $@" if $@;

	$self->{$table} = $schemaObject;

	return;
}

################################################################################
# methods that can be autogenerated
################################################################################

sub gen_schema_accessor {
	my $schema = shift;
	return sub { shift->{$schema} };
}

sub gen_new {
	my $table = shift;
	return sub { shift->{$table}{record}->new(@_) };
}

sub gen_count_where {
	my $table = shift;
	return sub {
		my ($self, $where) = @_;
		return $self->{$table}->count_where($where);
	};
}

sub gen_exists_where {
	my $table = shift;
	return sub {
		my ($self, $where) = @_;
		return $self->{$table}->exists_where($where);
	};
}

sub gen_list_where {
	my $table = shift;
	return sub {
		my ($self, $where, $order) = @_;
		if (wantarray) {
			return $self->{$table}->list_where($where, $order);
		} else {
			return $self->{$table}->list_where_i($where, $order);
		}
	};
}

sub gen_get_records_where {
	my $table = shift;
	return sub {
		my ($self, $where, $order) = @_;
		if (wantarray) {
			return $self->{$table}->get_records_where($where, $order);
		} else {
			return $self->{$table}->get_records_where_i($where, $order);
		}
	};
}

sub gen_insert_records {
	my $table = shift;
	return sub {
		my ($self, @records) = @_;
		if (@records == 1 and blessed $records[0] and $records[0]->isa("Iterator")) {
			return $self->{$table}->insert_records_i($records[0]);
		} else {
			return $self->{$table}->insert_records(@records);
		}
	};
}

sub gen_update_records {
	my $table = shift;
	return sub {
		my ($self, @records) = @_;
		if (@records == 1 and blessed $records[0] and $records[0]->isa("Iterator")) {
			return $self->{$table}->update_records_i($records[0]);
		} else {
			return $self->{$table}->update_records(@records);
		}
	};
}

sub gen_delete_where {
	my $table = shift;
	return sub {
		my ($self, $where) = @_;
		return $self->{$table}->delete_where($where);
	};
}

################################################################################
# create/rename/delete/dump/restore tables
################################################################################

sub create_tables {
	my ($self) = @_;

	foreach my $table (keys %$self) {
		next if $table =~ /^_/;                         # skip non-table self fields (none yet)
		next if $self->{$table}{params}{non_native};    # skip non-native tables
		my $schema_obj = $self->{$table};
		if ($schema_obj->can("create_table")) {
			$schema_obj->create_table;
		} else {
			warn "skipping creation of '$table' table: no create_table method\n";
		}
	}

	return 1;
}

sub rename_tables {
	my ($self, $new_ce) = @_;

	my $new_dblayout = databaseLayout($new_ce->{courseName});

	foreach my $table (keys %$self) {
		next if $table =~ /^_/;                         # skip non-table self fields (none yet)
		next if $self->{$table}{params}{non_native};    # skip non-native tables
		my $schema_obj = $self->{$table};
		if (exists $new_dblayout->{$table}) {
			if ($schema_obj->can("rename_table")) {
				# Get the new table names from the new dblayout.
				$schema_obj->rename_table($new_dblayout->{$table}{params}{tableOverride} // $table);
			} else {
				warn "skipping renaming of '$table' table: no rename_table method\n";
			}
		} else {
			warn "skipping renaming of '$table' table: table doesn't exist in new dbLayout\n";
		}
	}

	return 1;
}

sub delete_tables {
	my ($self) = @_;

	foreach my $table (keys %$self) {
		next if $table =~ /^_/;                         # skip non-table self fields (none yet)
		next if $self->{$table}{params}{non_native};    # skip non-native tables
		my $schema_obj = $self->{$table};
		if ($schema_obj->can("delete_table")) {
			$schema_obj->delete_table;
		} else {
			warn "skipping deletion of '$table' table: no delete_table method\n";
		}
	}

	return 1;
}

sub dump_tables {
	my ($self, $dump_dir) = @_;

	foreach my $table (keys %$self) {
		next if $table =~ /^_/;                         # skip non-table self fields (none yet)
		next if $self->{$table}{params}{non_native};    # skip non-native tables
		my $schema_obj = $self->{$table};
		if ($schema_obj->can("dump_table")) {
			my $dump_file = "$dump_dir/$table.sql";
			$schema_obj->dump_table($dump_file);
		} else {
			warn "skipping dump of '$table' table: no dump_table method\n";
		}
	}

	return 1;
}

sub restore_tables {
	my ($self, $dump_dir) = @_;

	foreach my $table (keys %$self) {
		next if $table =~ /^_/;                         # skip non-table self fields (none yet)
		next if $self->{$table}{params}{non_native};    # skip non-native tables
		my $schema_obj = $self->{$table};
		if ($schema_obj->can("restore_table")) {
			my $dump_file = "$dump_dir/$table.sql";
			$schema_obj->restore_table($dump_file);
		} else {
			warn "skipping restore of '$table' table: no restore_table method\n";
		}
	}

	return 1;
}

################################################################################
# transaction support
################################################################################

# Any course will have the user table, so that allows getting the database handle.

sub start_transaction {
	my $self = shift;
	eval { $self->{user}->dbh->begin_work; };
	if ($@) {
		my $msg = "Error in start_transaction: $@";
		if ($msg =~ /Already in a transaction/) {
			warn "Aborting active transaction.";
			$self->{user}->dbh->rollback;
		}
		croak $msg;
	}
}

sub end_transaction {
	my $self = shift;
	eval { $self->{user}->dbh->commit; };
	if ($@) {
		my $msg = "Error in end_transaction: $@";
		$self->abort_transaction;
		croak $msg;
	}
}

sub abort_transaction {
	my $self = shift;
	eval { $self->{user}->dbh->rollback; };
	if ($@) {
		my $msg = "Error in abort_transaction: $@";
		croak $msg;
	}
}

################################################################################
# user functions
################################################################################

BEGIN {
	*User            = gen_schema_accessor("user");
	*newUser         = gen_new("user");
	*countUsersWhere = gen_count_where("user");
	*existsUserWhere = gen_exists_where("user");
	*listUsersWhere  = gen_list_where("user");
	*getUsersWhere   = gen_get_records_where("user");
}

sub countUsers { return scalar shift->listUsers(@_) }

# Note: This returns a list of user_ids for all users except set level proctors.
sub listUsers {
	my ($self) = shift->checkArgs(\@_);
	if (wantarray) {
		return map {@$_} $self->{user}->get_fields_where(['user_id'], { user_id => { not_like => 'set_id:%' } });
	} else {
		return $self->{user}->count_where({ user_id => { not_like => 'set_id:%' } });
	}
}

sub existsUser {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return $self->{user}->exists($userID);
}

sub getUser {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return ($self->getUsers($userID))[0];
}

sub getUsers {
	my ($self, @userIDs) = shift->checkArgs(\@_, qw/user_id*/);
	return $self->{user}->gets(map { [$_] } @userIDs);
}

sub addUser {
	my ($self, $User) = shift->checkArgs(\@_, qw/REC:user/);
	return $self->{user}->add($User);
}

sub putUser {
	my ($self, $User) = shift->checkArgs(\@_, qw/REC:user/);
	my $rows = $self->{user}->put($User);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(error => 'putUser: user not found (perhaps you meant to use addUser?)')
		if $rows == 0;
	return $rows;
}

sub deleteUser {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	$self->deleteUserSet($userID, undef);
	$self->deletePassword($userID);
	$self->deleteGlobalUserAchievement($userID);
	$self->deletePermissionLevel($userID);
	$self->deleteKey($userID);
	$self->{past_answer}->delete_where({ user_id => $userID });
	return $self->{user}->delete($userID);
}

################################################################################
# password functions
################################################################################

BEGIN {
	*Password            = gen_schema_accessor("password");
	*newPassword         = gen_new("password");
	*countPasswordsWhere = gen_count_where("password");
	*existsPasswordWhere = gen_exists_where("password");
	*listPasswordsWhere  = gen_list_where("password");
	*getPasswordsWhere   = gen_get_records_where("password");
}

sub countPasswords { return scalar shift->countPasswords(@_) }

sub listPasswords {
	my ($self) = shift->checkArgs(\@_);
	if (wantarray) {
		return map {@$_} $self->{password}->get_fields_where(["user_id"]);
	} else {
		return $self->{password}->count_where;
	}
}

sub existsPassword {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return $self->{password}->exists($userID);
}

sub getPassword {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return ($self->getPasswords($userID))[0];
}

sub getPasswords {
	my ($self, @userIDs) = shift->checkArgs(\@_, qw/user_id*/);
	return $self->{password}->gets(map { [$_] } @userIDs);
}

sub addPassword {
	my ($self, $Password) = shift->checkArgs(\@_, qw/REC:password/);
	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addPassword: user ' . $Password->user_id . ' not found')
		unless $self->{user}->exists($Password->user_id);
	return $self->{password}->add($Password);
}

sub putPassword {
	my ($self, $Password) = shift->checkArgs(\@_, qw/REC:password/);
	my $rows = $self->{password}->put($Password);    # DBI returns 0E0 for 0.

	# AUTO-CREATE password records
	return $self->addPassword($Password) if $rows == 0;

	return $rows;
}

sub deletePassword {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return $self->{password}->delete($userID);
}

################################################################################
# permission functions
################################################################################

BEGIN {
	*PermissionLevel            = gen_schema_accessor("permission");
	*newPermissionLevel         = gen_new("permission");
	*countPermissionLevelsWhere = gen_count_where("permission");
	*existsPermissionLevelWhere = gen_exists_where("permission");
	*listPermissionLevelsWhere  = gen_list_where("permission");
	*getPermissionLevelsWhere   = gen_get_records_where("permission");
}

sub countPermissionLevels { return scalar shift->listPermissionLevels(@_) }

sub listPermissionLevels {
	my ($self) = shift->checkArgs(\@_);
	if (wantarray) {
		return map {@$_} $self->{permission}->get_fields_where(["user_id"]);
	} else {
		return $self->{permission}->count_where;
	}
}

sub existsPermissionLevel {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return $self->{permission}->exists($userID);
}

sub getPermissionLevel {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return ($self->getPermissionLevels($userID))[0];
}

sub getPermissionLevels {
	my ($self, @userIDs) = shift->checkArgs(\@_, qw/user_id*/);
	return $self->{permission}->gets(map { [$_] } @userIDs);
}

sub addPermissionLevel {
	my ($self, $PermissionLevel) = shift->checkArgs(\@_, qw/REC:permission/);
	WeBWorK::DB::Ex::DependencyNotFound->throw(
		error => 'addPermissionLevel: user ' . $PermissionLevel->user_id . ' not found')
		unless $self->{user}->exists($PermissionLevel->user_id);
	return $self->{permission}->add($PermissionLevel);
}

sub putPermissionLevel {
	my ($self, $PermissionLevel) = shift->checkArgs(\@_, qw/REC:permission/);
	my $rows = $self->{permission}->put($PermissionLevel);    # DBI returns 0E0 for 0.
	if ($rows == 0) {
		# AUTO-CREATE permission level records
		return $self->addPermissionLevel($PermissionLevel);
	} else {
		return $rows;
	}
}

sub deletePermissionLevel {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return $self->{permission}->delete($userID);
}

################################################################################
# key functions
################################################################################

BEGIN {
	*Key            = gen_schema_accessor("key");
	*countKeysWhere = gen_count_where("key");
	*existsKeyWhere = gen_exists_where("key");
	*listKeysWhere  = gen_list_where("key");
	# FIXME: getKeysWhere is never used, but if it is used the "session" in the returned keys is not JSON decoded.
	*getKeysWhere = gen_get_records_where("key");
}

sub newKey {
	my ($self, @values) = @_;
	my $key = $self->{key}{record}->new(@values);
	$key->session({}) unless ref($key->session) eq 'HASH';
	return $key;
}

sub countKeys { return scalar shift->listKeys(@_) }

sub listKeys {
	my ($self) = shift->checkArgs(\@_);
	if (wantarray) {
		return map {@$_} $self->{key}->get_fields_where(["user_id"]);
	} else {
		return $self->{key}->count_where;
	}
}

sub existsKey {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return $self->{key}->exists($userID);
}

sub getKey {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	my ($key) = $self->{key}->gets([$userID]);
	$key->session(decode_json($key->session)) if $key;
	return $key;
}

sub getKeys {
	my ($self, @userIDs) = shift->checkArgs(\@_, qw/user_id*/);
	my @keys = $self->{key}->gets(map { [$_] } @userIDs);
	$_->session(decode_json($_->session)) for @keys;
	return @keys;
}

sub addKey {
	my ($self, $Key) = shift->checkArgs(\@_, qw/VREC:key/);

	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addKey: user ' . $Key->user_id . ' not found')
		unless $Key->key eq "nonce" || $self->{user}->exists($Key->user_id);

	my $keyCopy = $self->newKey($Key);
	$keyCopy->session(encode_json($Key->session)) if ref($Key->session) eq 'HASH';

	return $self->{key}->add($keyCopy);
}

sub putKey {
	my ($self, $Key) = shift->checkArgs(\@_, qw/VREC:key/);
	my $keyCopy = $self->newKey($Key);
	$keyCopy->session(encode_json($Key->session)) if ref($Key->session) eq 'HASH';
	my $rows = $self->{key}->put($keyCopy);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(error => 'putKey: key not found (perhaps you meant to use addKey?)')
		if $rows == 0;
	return $rows;
}

sub deleteKey {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return $self->{key}->delete($userID);
}

################################################################################
# setting functions
################################################################################

BEGIN {
	*Setting             = gen_schema_accessor("setting");
	*newSetting          = gen_new("setting");
	*countSettingsWhere  = gen_count_where("setting");
	*existsSettingWhere  = gen_exists_where("setting");
	*listSettingsWhere   = gen_list_where("setting");
	*getSettingsWhere    = gen_get_records_where("setting");
	*addSettings         = gen_insert_records("setting");
	*putSettings         = gen_update_records("setting");
	*deleteSettingsWhere = gen_delete_where("setting");
}

# minimal set of routines for basic setting operation
# we don't need a full set, since the usage of settings is somewhat limited
# we also don't want to bother with records, since a setting is just a pair

sub settingExists {
	my ($self, $name) = @_;
	return $self->{setting}->exists_where([ name_eq => $name ]);
}

sub getSettingValue {
	my ($self, $name) = @_;

	return (map {@$_} $self->{setting}->get_fields_where(['value'], [ name_eq => $name ]))[0];
}

# we totally don't care if a setting already exists (and in fact i find that
# whole distinction somewhat annoying lately) so we hide the fact that we're
# either calling insert or update. at some point we could stand to add a
# method to Std.pm that used REPLACE INTO and then we'd be able to not care
# at all whether a setting was already there
sub setSettingValue {
	my ($self, $name, $value) = @_;
	if ($self->settingExists($name)) {
		return $self->{setting}->update_where({ value => $value }, [ name_eq => $name ]);
	} else {
		return $self->{setting}->insert_fields([ 'name', 'value' ], [ [ $name, $value ] ]);
	}
}

sub deleteSetting {
	my ($self, $name) = shift->checkArgs(\@_, qw/name/);
	return $self->{setting}->delete_where([ name_eq => $name ]);
}

################################################################################
# locations functions
################################################################################
# this database table is for ip restrictions by assignment
# the locations table defines names of locations consisting of
#    lists of ip masks (found in the location_addresses table)
#    to which assignments can be restricted to or denied from.

BEGIN {
	*Location            = gen_schema_accessor("locations");
	*newLocation         = gen_new("locations");
	*countLocationsWhere = gen_count_where("locations");
	*existsLocationWhere = gen_exists_where("locations");
	*listLocationsWhere  = gen_list_where("locations");
	*getLocationsWhere   = gen_get_records_where("locations");
}

sub countLocations { return scalar shift->listLocations(@_) }

sub listLocations {
	my ($self) = shift->checkArgs(\@_);
	if (wantarray) {
		return map {@$_} $self->{locations}->get_fields_where(["location_id"]);
	} else {
		return $self->{locations}->count_where;
	}
}

sub existsLocation {
	my ($self, $locationID) = shift->checkArgs(\@_, qw/location_id/);
	return $self->{locations}->exists($locationID);
}

sub getLocation {
	my ($self, $locationID) = shift->checkArgs(\@_, qw/location_id/);
	return ($self->getLocations($locationID))[0];
}

sub getLocations {
	my ($self, @locationIDs) = shift->checkArgs(\@_, qw/location_id*/);
	return $self->{locations}->gets(map { [$_] } @locationIDs);
}

sub getAllLocations {
	my ($self) = shift->checkArgs(\@_);
	return $self->{locations}->get_records_where();
}

sub addLocation {
	my ($self, $Location) = shift->checkArgs(\@_, qw/REC:locations/);
	return $self->{locations}->add($Location);
}

sub putLocation {
	my ($self, $Location) = shift->checkArgs(\@_, qw/REC:locations/);
	my $rows = $self->{locations}->put($Location);
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putLocation: location not found (perhaps you meant to use addLocation?)')
		if $rows == 0;
	return $rows;
}

sub deleteLocation {
	# do we need to allow calls from this package?  I can't think of
	#    any case where that would happen, but we include it for other
	#    deletions, so I'll keep it here.
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $locationID) = shift->checkArgs(\@_, "location_id$U");
	$self->deleteGlobalSetLocation(undef, $locationID);
	$self->deleteUserSetLocation(undef, undef, $locationID);

	# NOTE: the one piece of this that we don't address is if this
	#    results in all of the locations in a set's restriction being
	#    cleared; in this case, we should probably also reset the
	#    set->restrict_ip setting as well.  but that requires going
	#    out and doing a bunch of manipulations that well exceed what
	#    we want to do in this routine, so we'll assume that the user
	#    is smart enough to deal with that on her own.

	# addresses in the location_addresses table also need to be cleared
	$self->deleteLocationAddress($locationID, undef);

	return $self->{locations}->delete($locationID);
}

################################################################################
# location_addresses functions
################################################################################
# this database table is for ip restrictions by assignment
# the location_addresses table defines the ipmasks associate
#    with the locations that are used for restrictions.

BEGIN {
	*LocationAddress             = gen_schema_accessor("location_addresses");
	*newLocationAddress          = gen_new("location_addresses");
	*countLocationAddressesWhere = gen_count_where("location_addresses");
	*existsLocationAddressWhere  = gen_exists_where("location_addresses");
	*listLocationAddressesWhere  = gen_list_where("location_addresses");
	*getLocationAddressesWhere   = gen_get_records_where("location_addresses");
}

sub countAddressLocations { return scalar shift->listAddressLocations(@_) }

sub listAddressLocations {
	my ($self, $ipmask) = shift->checkArgs(\@_, qw/ip_mask/);
	my $where = [ ip_mask_eq => $ipmask ];
	if (wantarray) {
		return map {@$_} $self->{location_addresses}->get_fields_where(["location_id"], $where);
	} else {
		return $self->{location_addresses}->count_where($where);
	}
}

sub countLocationAddresses { return scalar shift->listLocationAddresses(@_) }

sub listLocationAddresses {
	my ($self, $locationID) = shift->checkArgs(\@_, qw/location_id/);
	my $where = [ location_id_eq => $locationID ];
	if (wantarray) {
		return map {@$_} $self->{location_addresses}->get_fields_where(["ip_mask"], $where);
	} else {
		return $self->{location_addresses}->count_where($where);
	}
}

sub existsLocationAddress {
	my ($self, $locationID, $ipmask) = shift->checkArgs(\@_, qw/location_id ip_mask/);
	return $self->{location_addresses}->exists($locationID, $ipmask);
}

# we wouldn't ever getLocationAddress or getLocationAddresses; to use those
#   we would have to know all of the information that we're getting

sub getAllLocationAddresses {
	my ($self, $locationID) = shift->checkArgs(\@_, qw/location_id/);
	my $where = [ location_id_eq => $locationID ];
	return $self->{location_addresses}->get_records_where($where);
}

sub addLocationAddress {
	my ($self, $LocationAddress) = shift->checkArgs(\@_, qw/REC:location_addresses/);
	WeBWorK::DB::Ex::DependencyNotFound->throw(
		error => 'addLocationAddress: location ' . $LocationAddress->location_id . ' not found')
		unless $self->{locations}->exists($LocationAddress->location_id);
	return $self->{location_addresses}->add($LocationAddress);
}

sub putLocationAddress {
	my ($self, $LocationAddress) = shift->checkArgs(\@_, qw/REC:location_addresses/);
	my $rows = $self->{location_addresses}->put($LocationAddress);
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putLocationAddress: location address not found (perhaps you meant to use addLocationAddress?)')
		if $rows == 0;
	return $rows;
}

sub deleteLocationAddress {
	# allow for undef values
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $locationID, $ipmask) = shift->checkArgs(\@_, "location_id$U", "ip_mask$U");
	return $self->{location_addresses}->delete($locationID, $ipmask);
}

################################################################################
# lti_launch_data functions
################################################################################
# This database table contains LTI launch data for LTI 1.3 authentication.

BEGIN {
	*LTILaunchData            = gen_schema_accessor("lti_launch_data");
	*existsLTILaunchDataWhere = gen_exists_where("lti_launch_data");
	*listLTILaunchDataWhere   = gen_list_where("lti_launch_data");
	*getLTILaunchDataWhere    = gen_get_records_where("lti_launch_data");
	*deleteLTILaunchDataWhere = gen_delete_where("lti_launch_data");
}

sub newLTILaunchData {
	my ($self, @data) = @_;
	my $ltiLaunchData = $self->{lti_launch_data}{record}->new(@data);
	$ltiLaunchData->data({}) unless ref($ltiLaunchData->data) eq 'HASH';
	return $ltiLaunchData;
}

sub getLTILaunchData {
	my ($self, $state) = shift->checkArgs(\@_, qw/state/);
	my ($ltiLaunchData) = $self->{lti_launch_data}->gets([$state]);
	$ltiLaunchData->data(decode_json($ltiLaunchData->data)) if $ltiLaunchData;
	return $ltiLaunchData;
}

sub addLTILaunchData {
	my ($self, $LTILaunchData) = shift->checkArgs(\@_, qw/REC:lti_launch_data/);
	my $launchDataCopy = $self->newLTILaunchData($LTILaunchData);
	$launchDataCopy->data(encode_json($LTILaunchData->data)) if ref($LTILaunchData->data) eq 'HASH';
	return $self->{lti_launch_data}->add($launchDataCopy);
}

sub putLTILaunchData {
	my ($self, $LTILaunchData) = shift->checkArgs(\@_, qw/REC:lti_launch_data/);
	my $launchDataCopy = $self->newLTILaunchData($LTILaunchData);
	$launchDataCopy->data(encode_json($LTILaunchData->data)) if ref($LTILaunchData->data) eq 'HASH';
	my $rows = $self->{lti_launch_data}->put($launchDataCopy);
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putLTILaunchData: lti launch data not found (perhaps you meant to use addLTILaunchData?)')
		if $rows == 0;
	return $rows;
}

sub deleteLTILaunchData {
	my ($self, $state) = shift->checkArgs(\@_, qw/state/);
	return $self->{lti_launch_data}->delete_where({ state => $state });
}

################################################################################
# lti_course_map functions
################################################################################
# This database table contains LTI launch data for LTI 1.3 authentication.

BEGIN {
	*LTICourseMap            = gen_schema_accessor("lti_course_map");
	*existsLTICourseMapWhere = gen_exists_where("lti_course_map");
	*getLTICourseMapsWhere   = gen_get_records_where("lti_course_map");
	*deleteLTICourseMapWhere = gen_delete_where("lti_course_map");
}

sub setLTICourseMap {
	my ($self, $course_id, $lms_context_id) = shift->checkArgs(\@_, qw/course_id lms_context_id/);
	if ($self->existsLTICourseMapWhere({ course_id => $course_id })) {
		return $self->{lti_course_map}
			->update_where({ lms_context_id => $lms_context_id }, { course_id => $course_id });
	} else {
		return $self->{lti_course_map}
			->insert_fields([ 'course_id', 'lms_context_id' ], [ [ $course_id, $lms_context_id ] ]);
	}
}

################################################################################
# past_answers functions
################################################################################

BEGIN {
	*PastAnswer             = gen_schema_accessor("past_answer");
	*newPastAnswer          = gen_new("past_answer");
	*countPastAnswersWhere  = gen_count_where("past_answer");
	*existsPastAnswersWhere = gen_exists_where("past_answer");
	*listPastAnswersWhere   = gen_list_where("past_answer");
	*getPastAnswersWhere    = gen_get_records_where("past_answer");
}

sub countProblemPastAnswers { return scalar shift->listPastAnswers(@_) }

sub listProblemPastAnswers {
	my ($self, $userID, $setID, $problemID);
	$self = shift;
	$self->checkArgs(\@_, qw/user_id set_id problem_id/);

	($userID, $setID, $problemID) = @_;
	my $where = [ user_id_eq_set_id_eq_problem_id_eq => $userID, $setID, $problemID ];

	my $order = ['answer_id'];

	if (wantarray) {
		return map {@$_} $self->{past_answer}->get_fields_where(["answer_id"], $where, $order);
	} else {
		return $self->{past_answer}->count_where($where);
	}
}

sub latestProblemPastAnswer {
	my ($self, $userID, $setID, $problemID);
	$self = shift;
	$self->checkArgs(\@_, qw/user_id set_id problem_id/);

	($userID, $setID, $problemID) = @_;
	my @answerIDs = $self->listProblemPastAnswers($userID, $setID, $problemID);

	#array should already be returned from lowest id to greatest.  Latest answer is greatest
	return $answerIDs[$#answerIDs];
}

sub existsPastAnswer {
	my ($self, $answerID) = shift->checkArgs(\@_, qw/answer_id/);
	return $self->{past_answer}->exists($answerID);
}

sub getPastAnswer {
	my ($self, $answerID) = shift->checkArgs(\@_, qw/answer_id/);
	return ($self->getPastAnswers([$answerID]))[0];
}

sub getPastAnswers {
	my ($self, @answerIDs) = shift->checkArgsRefList(\@_, qw/answer_id*/);
	return $self->{past_answer}->gets(map { [$_] } @answerIDs);
}

sub addPastAnswer {
	my ($self, $pastAnswer) = shift->checkArgs(\@_, qw/REC:past_answer/);

	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addPastAnswer: user problem '
			. $pastAnswer->user_id . ' '
			. $pastAnswer->set_id . ' '
			. $pastAnswer->problem_id
			. ' not found')
		unless $self->{problem_user}->exists($pastAnswer->user_id, $pastAnswer->set_id, $pastAnswer->problem_id);

	return $self->{past_answer}->add($pastAnswer);
}

sub putPastAnswer {
	my ($self, $pastAnswer) = shift->checkArgs(\@_, qw/REC:past_answer/);
	my $rows = $self->{past_answer}->put($pastAnswer);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putPastAnswer: past answer not found (perhaps you meant to use addPastAnswer?)')
		if $rows == 0;
	return $rows;
}

sub deletePastAnswer {
	# userID and achievementID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $answer_id) = shift->checkArgs(\@_, "answer_id$U");
	return $self->{past_answer}->delete($answer_id);
}

################################################################################
# set functions
################################################################################

BEGIN {
	*GlobalSet            = gen_schema_accessor("set");
	*newGlobalSet         = gen_new("set");
	*countGlobalSetsWhere = gen_count_where("set");
	*existsGlobalSetWhere = gen_exists_where("set");
	*listGlobalSetsWhere  = gen_list_where("set");
	*getGlobalSetsWhere   = gen_get_records_where("set");
}

sub countGlobalSets { return scalar shift->listGlobalSets(@_) }

sub listGlobalSets {
	my ($self) = shift->checkArgs(\@_);
	if (wantarray) {
		return map {@$_} $self->{set}->get_fields_where(["set_id"]);
	} else {
		return $self->{set}->count_where;
	}
}

sub existsGlobalSet {
	my ($self, $setID) = shift->checkArgs(\@_, qw/set_id/);
	return $self->{set}->exists($setID);
}

sub getGlobalSet {
	my ($self, $setID) = shift->checkArgs(\@_, qw/set_id/);
	return ($self->getGlobalSets($setID))[0];
}

sub getGlobalSets {
	my ($self, @setIDs) = shift->checkArgs(\@_, qw/set_id*/);
	return $self->{set}->gets(map { [$_] } @setIDs);
}

sub addGlobalSet {
	my ($self, $GlobalSet) = shift->checkArgs(\@_, qw/REC:set/);
	return $self->{set}->add($GlobalSet);
}

sub putGlobalSet {
	my ($self, $GlobalSet) = shift->checkArgs(\@_, qw/REC:set/);
	my $rows = $self->{set}->put($GlobalSet);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putGlobalSet: global set not found (perhaps you meant to use addGlobalSet?)')
		if $rows == 0;
	return $rows;
}

sub deleteGlobalSet {
	# setID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $setID) = shift->checkArgs(\@_, "set_id$U");
	$self->deleteUserSet(undef, $setID);
	$self->deleteGlobalProblem($setID, undef);
	$self->deleteGlobalSetLocation($setID, undef);
	return $self->{set}->delete($setID);
}

####################################################################
## achievement functions
###############################################################

BEGIN {
	*Achievement            = gen_schema_accessor("achievement");
	*newAchievement         = gen_new("achievement");
	*countAchievementsWhere = gen_count_where("achievement");
	*existsAchievementWhere = gen_exists_where("achievement");
	*listAchievementsWhere  = gen_list_where("achievement");
	*getAchievementsWhere   = gen_get_records_where("achievement");
}

sub countAchievements { return scalar shift->listAchievements(@_) }

sub listAchievements {
	my ($self) = shift->checkArgs(\@_);
	if (wantarray) {
		return map {@$_} $self->{achievement}->get_fields_where(["achievement_id"]);
	} else {
		return $self->{achievement}->count_where;
	}
}

sub existsAchievement {
	my ($self, $achievementID) = shift->checkArgs(\@_, qw/achievement_id/);
	return $self->{achievement}->exists($achievementID);
}

sub getAchievement {
	my ($self, $achievementID) = shift->checkArgs(\@_, qw/achievement_id/);
	return ($self->getAchievements($achievementID))[0];
}

sub getAchievements {
	my ($self, @achievementIDs) = shift->checkArgs(\@_, qw/achievement_id*/);
	return $self->{achievement}->gets(map { [$_] } @achievementIDs);
}

sub getAchievementCategories {
	my ($self) = shift->checkArgs(\@_);
	return map {@$_} $self->{achievement}->get_fields_where("DISTINCT category", undef, "category");
}

sub addAchievement {
	my ($self, $Achievement) = shift->checkArgs(\@_, qw/REC:achievement/);
	return $self->{achievement}->add($Achievement);
}

sub putAchievement {
	my ($self, $Achievement) = shift->checkArgs(\@_, qw/REC:achievement/);
	my $rows = $self->{achievement}->put($Achievement);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putAchievement: achievement not found (perhaps you meant to use addAchievement?)')
		if $rows == 0;
	return $rows;
}

sub deleteAchievement {
	# achievementID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $achievementID) = shift->checkArgs(\@_, "achievement_id$U");
	$self->deleteUserAchievement(undef, $achievementID);
	return $self->{achievement}->delete($achievementID);
}

####################################################################
## global_user_achievement functions
###############################################################

BEGIN {
	*GlobalUserAchievement            = gen_schema_accessor("global_user_achievement");
	*newGlobalUserAchievement         = gen_new("global_user_achievement");
	*countGlobalUserAchievementsWhere = gen_count_where("global_user_achievement");
	*existsGlobalUserAchievementWhere = gen_exists_where("global_user_achievement");
	*listGlobalUserAchievementsWhere  = gen_list_where("global_user_achievement");
	*getGlobalUserAchievementsWhere   = gen_get_records_where("global_user_achievement");
}

sub countGlobalUserAchievements { return scalar shift->listGlobalUserAchievements(@_) }

sub listGlobalUserAchievements {
	my ($self) = shift->checkArgs(\@_);
	if (wantarray) {
		return map {@$_} $self->{global_user_achievement}->get_fields_where(["user_id"]);
	} else {
		return $self->{global_user_achievement}->count_where;
	}
}

sub existsGlobalUserAchievement {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return $self->{global_user_achievement}->exists($userID);
}

sub getGlobalUserAchievement {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	return ($self->getGlobalUserAchievements($userID))[0];
}

sub getGlobalUserAchievements {
	my ($self, @userIDs) = shift->checkArgs(\@_, qw/user_id*/);
	return $self->{global_user_achievement}->gets(map { [$_] } @userIDs);
}

sub addGlobalUserAchievement {
	my ($self, $globalUserAchievement) = shift->checkArgs(\@_, qw/REC:global_user_achievement/);
	return $self->{global_user_achievement}->add($globalUserAchievement);
}

sub putGlobalUserAchievement {
	my ($self, $globalUserAchievement) = shift->checkArgs(\@_, qw/REC:global_user_achievement/);
	my $rows = $self->{global_user_achievement}->put($globalUserAchievement);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(error =>
			'putGlobalUserAchievement: user achievement not found (perhaps you meant to use addGlobalUserAchievement?)')
		if $rows == 0;
	return $rows;
}

sub deleteGlobalUserAchievement {
	# userAchievementID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $userID) = shift->checkArgs(\@_, "user_id$U");
	$self->{achievement_user}->delete_where({ user_id => $userID });
	return $self->{global_user_achievement}->delete($userID);
}

################################################################################
# achievement_user functions
################################################################################

BEGIN {
	*UserAchievement            = gen_schema_accessor("achievement_user");
	*newUserAchievement         = gen_new("achievement_user");
	*countUserAchievementsWhere = gen_count_where("achievement_user");
	*existsUserAchievementWhere = gen_exists_where("achievement_user");
	*listUserAchievementsWhere  = gen_list_where("achievement_user");
	*getUserAchievementsWhere   = gen_get_records_where("achievement_user");
}

sub countAchievementUsers { return scalar shift->listAchievementUsers(@_) }

sub listAchievementUsers {
	my ($self, $achievementID) = shift->checkArgs(\@_, qw/achievement_id/);
	my $where = [ achievement_id_eq => $achievementID ];
	if (wantarray) {
		return map {@$_} $self->{achievement_user}->get_fields_where(["user_id"], $where);
	} else {
		return $self->{achievement_user}->count_where($where);
	}
}

sub countUserAchievements { return scalar shift->listUserAchievements(@_) }

sub listUserAchievements {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	my $where = [ user_id_eq => $userID ];
	if (wantarray) {
		return map {@$_} $self->{achievement_user}->get_fields_where(["achievement_id"], $where);
	} else {
		return $self->{achievement_user}->count_where($where);
	}
}

sub existsUserAchievement {
	my ($self, $userID, $achievementID) = shift->checkArgs(\@_, qw/user_id achievement_id/);
	return $self->{achievement_user}->exists($userID, $achievementID);
}

sub getUserAchievement {
	my ($self, $userID, $achievementID) = shift->checkArgs(\@_, qw/user_id achievement_id/);
	return ($self->getUserAchievements([ $userID, $achievementID ]))[0];
}

sub getUserAchievements {
	my ($self, @userAchievementIDs) = shift->checkArgsRefList(\@_, qw/user_id achievement_id/);
	return $self->{achievement_user}->gets(@userAchievementIDs);
}

sub addUserAchievement {
	my ($self, $UserAchievement) = shift->checkArgs(\@_, qw/REC:achievement_user/);

	WeBWorK::DB::Ex::DependencyNotFound->throw(
		error => 'addUserAchievement: user ' . $UserAchievement->user_id . ' not found')
		unless $self->{user}->exists($UserAchievement->user_id);
	WeBWorK::DB::Ex::DependencyNotFound->throw(
		error => 'addUserAchievement: achievement ' . $UserAchievement->achievement_id . ' not found')
		unless $self->{achievement}->exists($UserAchievement->achievement_id);

	return $self->{achievement_user}->add($UserAchievement);
}

sub putUserAchievement {
	my ($self, $UserAchievement) = shift->checkArgs(\@_, qw/REC:achievement_user/);
	my $rows = $self->{achievement_user}->put($UserAchievement);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putUserAchievement: user achievement not found (perhaps you meant to use addUserAchievement?)')
		if $rows == 0;
	return $rows;
}

sub deleteUserAchievement {
	# userID and achievementID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $userID, $achievementID) = shift->checkArgs(\@_, "user_id$U", "achievement_id$U");
	return $self->{achievement_user}->delete($userID, $achievementID);
}

################################################################################
# set_user functions
################################################################################

BEGIN {
	*UserSet            = gen_schema_accessor("set_user");
	*newUserSet         = gen_new("set_user");
	*countUserSetsWhere = gen_count_where("set_user");
	*existsUserSetWhere = gen_exists_where("set_user");
	*listUserSetsWhere  = gen_list_where("set_user");
	*getUserSetsWhere   = gen_get_records_where("set_user");
}

sub countSetUsers { return scalar shift->listSetUsers(@_) }

sub listSetUsers {
	my ($self, $setID) = shift->checkArgs(\@_, qw/set_id/);
	my $where = [ set_id_eq => $setID ];
	if (wantarray) {
		return map {@$_} $self->{set_user}->get_fields_where(["user_id"], $where);
	} else {
		return $self->{set_user}->count_where($where);
	}
}

sub countUserSets { return scalar shift->listUserSets(@_) }

sub listUserSets {
	my ($self, $userID) = shift->checkArgs(\@_, qw/user_id/);
	my $where = [ user_id_eq => $userID ];
	if (wantarray) {
		return map {@$_} $self->{set_user}->get_fields_where(["set_id"], $where);
	} else {
		return $self->{set_user}->count_where($where);
	}
}

sub existsUserSet {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	return $self->{set_user}->exists($userID, $setID);
}

sub getUserSet {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	return ($self->getUserSets([ $userID, $setID ]))[0];
}

sub getUserSets {
	my ($self, @userSetIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id/);
	return $self->{set_user}->gets(@userSetIDs);
}

# the code from addUserSet() is duplicated in large part following in
# addVersionedUserSet; changes here should accordingly be propagated down there
sub addUserSet {
	my ($self, $UserSet) = shift->checkArgs(\@_, qw/REC:set_user/);
	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addUserSet: user ' . $UserSet->user_id . ' not found')
		unless $self->{user}->exists($UserSet->user_id);
	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addUserSet: set ' . $UserSet->set_id . ' not found')
		unless $self->{set}->exists($UserSet->set_id);
	return $self->{set_user}->add($UserSet);
}

# the code from putUserSet() is duplicated in large part in the following
# putVersionedUserSet; c.f. that routine
sub putUserSet {
	my ($self, $UserSet) = shift->checkArgs(\@_, qw/REC:set_user/);
	my $rows = $self->{set_user}->put($UserSet);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putUserSet: user set not found (perhaps you meant to use addUserSet?)')
		if $rows == 0;
	return $rows;
}

sub deleteUserSet {
	# userID and setID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $userID, $setID) = shift->checkArgs(\@_, "user_id$U", "set_id$U");
	$self->deleteSetVersion($userID, $setID, undef);
	$self->deleteUserProblem($userID, $setID, undef);
	return $self->{set_user}->delete($userID, $setID);
}

################################################################################
# set_merged functions
################################################################################

BEGIN {
	*MergedSet = gen_schema_accessor("set_merged");
	#*newMergedSet = gen_new("set_merged");
	#*countMergedSetsWhere = gen_count_where("set_merged");
	*existsMergedSetWhere = gen_exists_where("set_merged");
	#*listMergedSetsWhere = gen_list_where("set_merged");
	*getMergedSetsWhere = gen_get_records_where("set_merged");
}

sub existsMergedSet {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	return $self->{set_merged}->exists($userID, $setID);
}

sub getMergedSet {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	return ($self->getMergedSets([ $userID, $setID ]))[0];
}

sub getMergedSets {
	my ($self, @userSetIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id/);
	return $self->{set_merged}->gets(@userSetIDs);
}

################################################################################
# set_version functions (NEW)
################################################################################

BEGIN {
	*SetVersion            = gen_schema_accessor("set_version");
	*newSetVersion         = gen_new("set_version");
	*countSetVersionsWhere = gen_count_where("set_version");
	*existsSetVersionWhere = gen_exists_where("set_version");
	*listSetVersionsWhere  = gen_list_where("set_version");
	*getSetVersionsWhere   = gen_get_records_where("set_version");
}

# versioned analog of countUserSets
sub countSetVersions { return scalar shift->listSetVersions(@_) }

# versioned analog of listUserSets
sub listSetVersions {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	my $where = [ user_id_eq_set_id_eq => $userID, $setID ];
	my $order = ['version_id'];
	if (wantarray) {
		return map {@$_} $self->{set_version}->get_fields_where(["version_id"], $where, $order);
	} else {
		return $self->{set_version}->count_where($where);
	}
}

# versioned analog of existsUserSet
sub existsSetVersion {
	my ($self, $userID, $setID, $versionID) = shift->checkArgs(\@_, qw/user_id set_id version_id/);
	return $self->{set_version}->exists($userID, $setID, $versionID);
}

# versioned analog of getUserSet
sub getSetVersion {
	my ($self, $userID, $setID, $versionID) = shift->checkArgs(\@_, qw/user_id set_id version_id/);
	return ($self->getSetVersions([ $userID, $setID, $versionID ]))[0];
}

# versioned analog of getUserSets
sub getSetVersions {
	my ($self, @setVersionIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id version_id/);
	return $self->{set_version}->gets(@setVersionIDs);
}

# versioned analog of addUserSet
sub addSetVersion {
	my ($self, $SetVersion) = shift->checkArgs(\@_, qw/REC:set_version/);
	WeBWorK::DB::Ex::DependencyNotFound->throw(
		error => 'addSetVersion: set ' . $SetVersion->set_id . ' not found for user ' . $SetVersion->user_id)
		unless $self->{set_user}->exists($SetVersion->user_id, $SetVersion->set_id);
	return $self->{set_version}->add($SetVersion);
}

# versioned analog of putUserSet
sub putSetVersion {
	my ($self, $SetVersion) = shift->checkArgs(\@_, qw/REC:set_version/);
	my $rows = $self->{set_version}->put($SetVersion);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putSetVersion: set version not found (perhaps you meant to use addSetVersion?)')
		if $rows == 0;
	return $rows;
}

# versioned analog of deleteUserSet
sub deleteSetVersion {
	# userID, setID, and versionID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $userID, $setID, $versionID) = shift->checkArgs(\@_, "user_id$U", "set_id$U", "version_id$U");
	$self->deleteProblemVersion($userID, $setID, $versionID, undef);
	return $self->{set_version}->delete($userID, $setID, $versionID);
}

################################################################################
# set_version_merged functions (NEW)
################################################################################

BEGIN {
	*MergedSetVersion = gen_schema_accessor("set_version_merged");
	#*newMergedSetVersion = gen_new("set_version_merged");
	#*countMergedSetVersionsWhere = gen_count_where("set_version_merged");
	*existsMergedSetVersionWhere = gen_exists_where("set_version_merged");
	#*listMergedSetVersionsWhere = gen_list_where("set_version_merged");
	*getMergedSetVersionsWhere = gen_get_records_where("set_version_merged");
}

sub existsMergedSetVersion {
	my ($self, $userID, $setID, $versionID) = shift->checkArgs(\@_, qw/user_id set_id version_id/);
	return $self->{set_version_merged}->exists($userID, $setID, $versionID);
}

sub getMergedSetVersion {
	my ($self, $userID, $setID, $versionID) = shift->checkArgs(\@_, qw/user_id set_id version_id/);
	return ($self->getMergedSetVersions([ $userID, $setID, $versionID ]))[0];
}

sub getMergedSetVersions {
	my ($self, @setVersionIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id version_id/);
	return $self->{set_version_merged}->gets(@setVersionIDs);
}

################################################################################
# set_locations functions
################################################################################
# this database table is for ip restrictions by assignment
# the set_locations table defines the association between a
#    global set and the locations to which the set may be
#    restricted or denied.

BEGIN {
	*GlobalSetLocation            = gen_schema_accessor("set_locations");
	*newGlobalSetLocation         = gen_new("set_locations");
	*countGlobalSetLocationsWhere = gen_count_where("set_locations");
	*existsGlobalSetLocationWhere = gen_exists_where("set_locations");
	*listGlobalSetLocationsWhere  = gen_list_where("set_locations");
	*getGlobalSetLocationsWhere   = gen_get_records_where("set_locations");
}

sub countGlobalSetLocations { return scalar shift->listGlobalSetLocations(@_) }

sub listGlobalSetLocations {
	my ($self, $setID) = shift->checkArgs(\@_, qw/set_id/);
	my $where = [ set_id_eq => $setID ];
	if (wantarray) {
		my $order = ['location_id'];
		return map {@$_} $self->{set_locations}->get_fields_where(["location_id"], $where, $order);
	} else {
		return $self->{set_user}->count_where($where);
	}
}

sub existsGlobalSetLocation {
	my ($self, $setID, $locationID) = shift->checkArgs(\@_, qw/set_id location_id/);
	return $self->{set_locations}->exists($setID, $locationID);
}

sub getGlobalSetLocation {
	my ($self, $setID, $locationID) = shift->checkArgs(\@_, qw/set_id location_id/);
	return ($self->getGlobalSetLocations([ $setID, $locationID ]))[0];
}

sub getGlobalSetLocations {
	my ($self, @locationIDs) = shift->checkArgsRefList(\@_, qw/set_id location_id/);
	return $self->{set_locations}->gets(@locationIDs);
}

sub getAllGlobalSetLocations {
	my ($self, $setID) = shift->checkArgs(\@_, qw/set_id/);
	my $where = [ set_id_eq => $setID ];
	return $self->{set_locations}->get_records_where($where);
}

sub addGlobalSetLocation {
	my ($self, $GlobalSetLocation) = shift->checkArgs(\@_, qw/REC:set_locations/);
	WeBWorK::DB::Ex::DependencyNotFound->throw(
		error => 'addGlobalSetLocation: set ' . $GlobalSetLocation->set_id . ' not found')
		unless $self->{set}->exists($GlobalSetLocation->set_id);
	return $self->{set_locations}->add($GlobalSetLocation);
}

sub putGlobalSetLocation {
	my ($self, $GlobalSetLocation) = shift->checkArgs(\@_, qw/REC:set_locations/);
	my $rows = $self->{set_locations}->put($GlobalSetLocation);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putGlobalSetLocation: global problem not found (perhaps you meant to use addGlobalSetLocation?)')
		if $rows == 0;
	return $rows;
}

sub deleteGlobalSetLocation {
	# setID and locationID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $setID, $locationID) = shift->checkArgs(\@_, "set_id$U", "location_id$U");
	$self->deleteUserSetLocation(undef, $setID, $locationID);
	return $self->{set_locations}->delete($setID, $locationID);
}

################################################################################
# set_locations_user functions
################################################################################
# this database table is for ip restrictions by assignment
# the set_locations_user table defines the set_user level
#    modifications to the set_locations defined for the
#    global set

BEGIN {
	*UserSetLocation            = gen_schema_accessor("set_locations_user");
	*newUserSetLocation         = gen_new("set_locations_user");
	*countUserSetLocationWhere  = gen_count_where("set_locations_user");
	*existsUserSetLocationWhere = gen_exists_where("set_locations_user");
	*listUserSetLocationsWhere  = gen_list_where("set_locations_user");
	*getUserSetLocationsWhere   = gen_get_records_where("set_locations_user");
}

sub countSetLocationUsers { return scalar shift->listSetLocationUsers(@_) }

sub listSetLocationUsers {
	my ($self, $setID, $locationID) = shift->checkArgs(\@_, qw/set_id location_id/);
	my $where = [ set_id_eq_location_id_eq => $setID, $locationID ];
	if (wantarray) {
		return map {@$_} $self->{set_locations_user}->get_fields_where(["user_id"], $where);
	} else {
		return $self->{set_locations_user}->count_where($where);
	}
}

sub countUserSetLocations { return scalar shift->listUserSetLocations(@_) }

sub listUserSetLocations {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	my $where = [ user_id_eq_set_id_eq => $userID, $setID ];
	if (wantarray) {
		return map {@$_} $self->{set_locations_user}->get_fields_where(["location_id"], $where);
	} else {
		return $self->{set_locations_user}->count_where($where);
	}
}

sub existsUserSetLocation {
	my ($self, $userID, $setID, $locationID) = shift->checkArgs(\@_, qw/user_id set_id location_id/);
	return $self->{set_locations_user}->exists($userID, $setID, $locationID);
}

# FIXME: we won't ever use this because all fields are key fields
sub getUserSetLocation {
	my ($self, $userID, $setID, $locationID) = shift->checkArgs(\@_, qw/user_id set_id location_id/);
	return ($self->getUserSetLocations([ $userID, $setID, $locationID ]))[0];
}

# FIXME: we won't ever use this because all fields are key fields
sub getUserSetLocations {
	my ($self, @userSetLocationIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id location_id/);
	return $self->{set_locations_user}->gets(@userSetLocationIDs);
}

sub getAllUserSetLocations {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	my $where = [ user_id_eq_set_id_eq => $userID, $setID ];
	return $self->{set_locations_user}->get_records_where($where);
}

sub addUserSetLocation {
	# VERSIONING - accept versioned ID fields
	my ($self, $UserSetLocation) = shift->checkArgs(\@_, qw/VREC:set_locations_user/);
	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addUserSetLocation: user set '
			. $UserSetLocation->set_id
			. ' for user '
			. $UserSetLocation->user_id
			. ' not found')
		unless $self->{set_user}->exists($UserSetLocation->user_id, $UserSetLocation->set_id);
	return $self->{set_locations_user}->add($UserSetLocation);
}

# FIXME: we won't ever use this because all fields are key fields
# versioned_ok is an optional argument which lets us slip versioned setIDs through checkArgs.
sub putUserSetLocation {
	my $V = $_[2] ? "V" : "";
	my ($self, $UserSetLocation, undef) = shift->checkArgs(\@_, "${V}REC:set_locations_user", "versioned_ok!?");

	my $rows = $self->{set_locations_user}->put($UserSetLocation);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putUserSetLocation: user set location not found (perhaps you meant to use addUserSetLocation?)')
		if $rows == 0;
	return $rows;
}

sub deleteUserSetLocation {
	# userID, setID, and locationID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $userID, $setID, $locationID) = shift->checkArgs(\@_, "user_id$U", "set_id$U", "set_locations_id$U");
	return $self->{set_locations_user}->delete($userID, $setID, $locationID);
}

################################################################################
# set_locations_merged functions
################################################################################
# this is different from other set_merged functions, because
#    in this case the only data that we have are the set_id,
#    location_id, and user_id, and we want to replace all
#    locations from GlobalSetLocations with those from
#    UserSetLocations if the latter exist.

sub getAllMergedSetLocations {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);

	if ($self->countUserSetLocations($userID, $setID)) {
		return $self->getAllUserSetLocations($userID, $setID);
	} else {
		return $self->getAllGlobalSetLocations($setID);
	}
}

################################################################################
# problem functions
################################################################################

BEGIN {
	*GlobalProblem            = gen_schema_accessor("problem");
	*newGlobalProblem         = gen_new("problem");
	*countGlobalProblemsWhere = gen_count_where("problem");
	*existsGlobalProblemWhere = gen_exists_where("problem");
	*listGlobalProblemsWhere  = gen_list_where("problem");
	*getGlobalProblemsWhere   = gen_get_records_where("problem");
}

sub countGlobalProblems { return scalar shift->listGlobalProblems(@_) }

sub listGlobalProblems {
	my ($self, $setID) = shift->checkArgs(\@_, qw/set_id/);
	my $where = [ set_id_eq => $setID ];
	if (wantarray) {
		return map {@$_} $self->{problem}->get_fields_where(["problem_id"], $where);
	} else {
		return $self->{problem}->count_where($where);
	}
}

sub existsGlobalProblem {
	my ($self, $setID, $problemID) = shift->checkArgs(\@_, qw/set_id problem_id/);
	return $self->{problem}->exists($setID, $problemID);
}

sub getGlobalProblem {
	my ($self, $setID, $problemID) = shift->checkArgs(\@_, qw/set_id problem_id/);
	return ($self->getGlobalProblems([ $setID, $problemID ]))[0];
}

sub getGlobalProblems {
	my ($self, @problemIDs) = shift->checkArgsRefList(\@_, qw/set_id problem_id/);
	return $self->{problem}->gets(@problemIDs);
}

sub getAllGlobalProblems {
	my ($self, $setID) = shift->checkArgs(\@_, qw/set_id/);
	my $where = [ set_id_eq => $setID ];
	return $self->{problem}->get_records_where($where);
}

sub addGlobalProblem {
	my ($self, $GlobalProblem) = shift->checkArgs(\@_, qw/REC:problem/);
	WeBWorK::DB::Ex::DependencyNotFound->throw(
		error => 'addGlobalProblem: set ' . $GlobalProblem->set_id . ' not found')
		unless $self->{set}->exists($GlobalProblem->set_id);
	return $self->{problem}->add($GlobalProblem);
}

sub putGlobalProblem {
	my ($self, $GlobalProblem) = shift->checkArgs(\@_, qw/REC:problem/);
	my $rows = $self->{problem}->put($GlobalProblem);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putGlobalProblem: global problem not found (perhaps you meant to use addGlobalProblem?)')
		if $rows == 0;
	return $rows;
}

sub deleteGlobalProblem {
	# userID and setID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $setID, $problemID) = shift->checkArgs(\@_, "set_id$U", "problem_id$U");
	$self->deleteUserProblem(undef, $setID, $problemID);
	return $self->{problem}->delete($setID, $problemID);
}

################################################################################
# problem_user functions
################################################################################

BEGIN {
	*UserProblem            = gen_schema_accessor("problem_user");
	*newUserProblem         = gen_new("problem_user");
	*countUserProblemsWhere = gen_count_where("problem_user");
	*existsUserProblemWhere = gen_exists_where("problem_user");
	*listUserProblemsWhere  = gen_list_where("problem_user");
	*getUserProblemsWhere   = gen_get_records_where("problem_user");
}

sub countProblemUsers { return scalar shift->listProblemUsers(@_) }

sub listProblemUsers {
	my ($self, $setID, $problemID) = shift->checkArgs(\@_, qw/set_id problem_id/);
	my $where = [ set_id_eq_problem_id_eq => $setID, $problemID ];
	if (wantarray) {
		return map {@$_} $self->{problem_user}->get_fields_where(["user_id"], $where);
	} else {
		return $self->{problem_user}->count_where($where);
	}
}

sub countUserProblems { return scalar shift->listUserProblems(@_) }

sub listUserProblems {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	my $where = [ user_id_eq_set_id_eq => $userID, $setID ];
	if (wantarray) {
		return map {@$_} $self->{problem_user}->get_fields_where(["problem_id"], $where);
	} else {
		return $self->{problem_user}->count_where($where);
	}
}

sub existsUserProblem {
	my ($self, $userID, $setID, $problemID) = shift->checkArgs(\@_, qw/user_id set_id problem_id/);
	return $self->{problem_user}->exists($userID, $setID, $problemID);
}

sub getUserProblem {
	my ($self, $userID, $setID, $problemID) = shift->checkArgs(\@_, qw/user_id set_id problem_id/);
	return ($self->getUserProblems([ $userID, $setID, $problemID ]))[0];
}

sub getUserProblems {
	my ($self, @userProblemIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id problem_id/);
	return $self->{problem_user}->gets(@userProblemIDs);
}

sub getAllUserProblems {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	my $where = [ user_id_eq_set_id_eq => $userID, $setID ];
	return $self->{problem_user}->get_records_where($where);
}

sub addUserProblem {
	# VERSIONING - accept versioned ID fields
	my ($self, $UserProblem) = shift->checkArgs(\@_, qw/VREC:problem_user/);

	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addUserProblem: user set '
			. $UserProblem->set_id
			. ' for user '
			. $UserProblem->user_id
			. ' not found')
		unless $self->{set_user}->exists($UserProblem->user_id, $UserProblem->set_id);

	my ($nv_set_id, $versionNum) = grok_vsetID($UserProblem->set_id);

	WeBWorK::DB::Ex::DependencyNotFound->throw(
		error => 'addUserProblem: problem ' . $UserProblem->problem_id . ' in set $nv_set_id not found')
		unless $self->{problem}->exists($nv_set_id, $UserProblem->problem_id);

	return $self->{problem_user}->add($UserProblem);
}

# versioned_ok is an optional argument which lets us slip versioned setIDs through checkArgs.
sub putUserProblem {
	my $V = $_[2] ? "V" : "";
	my ($self, $UserProblem, undef) = shift->checkArgs(\@_, "${V}REC:problem_user", "versioned_ok!?");

	my $rows = $self->{problem_user}->put($UserProblem);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putUserProblem: user problem not found (perhaps you meant to use addUserProblem?)')
		if $rows == 0;
	return $rows;
}

sub deleteUserProblem {
	# userID, setID, and problemID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $userID, $setID, $problemID) = shift->checkArgs(\@_, "user_id$U", "set_id$U", "problem_id$U");
	return $self->{problem_user}->delete($userID, $setID, $problemID);
}

################################################################################
# problem_merged functions
################################################################################

BEGIN {
	*MergedProblem = gen_schema_accessor("problem_merged");
	#*newMergedProblem = gen_new("problem_merged");
	#*countMergedProblemsWhere = gen_count_where("problem_merged");
	*existsMergedProblemWhere = gen_exists_where("problem_merged");
	#*listMergedProblemsWhere = gen_list_where("problem_merged");
	*getMergedProblemsWhere = gen_get_records_where("problem_merged");
}

sub existsMergedProblem {
	my ($self, $userID, $setID, $problemID) = shift->checkArgs(\@_, qw/user_id set_id problem_id/);
	return $self->{problem_merged}->exists($userID, $setID, $problemID);
}

sub getMergedProblem {
	my ($self, $userID, $setID, $problemID) = shift->checkArgs(\@_, qw/user_id set_id problem_id/);
	return ($self->getMergedProblems([ $userID, $setID, $problemID ]))[0];
}

sub getMergedProblems {
	my ($self, @userProblemIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id problem_id/);
	return $self->{problem_merged}->gets(@userProblemIDs);
}

sub getAllMergedUserProblems {
	my ($self, $userID, $setID) = shift->checkArgs(\@_, qw/user_id set_id/);
	my $where = [ user_id_eq_set_id_eq => $userID, $setID ];
	return $self->{problem_merged}->get_records_where($where);
}

################################################################################
# problem_version functions (NEW)
################################################################################

BEGIN {
	*ProblemVersion            = gen_schema_accessor("problem_version");
	*newProblemVersion         = gen_new("problem_version");
	*countProblemVersionsWhere = gen_count_where("problem_version");
	*existsProblemVersionWhere = gen_exists_where("problem_version");
	*listProblemVersionsWhere  = gen_list_where("problem_version");
	*getProblemVersionsWhere   = gen_get_records_where("problem_version");
}

# versioned analog of countUserProblems
sub countProblemVersions { return scalar shift->listProblemVersions(@_) }

# versioned analog of listUserProblems
sub listProblemVersions {
	my ($self, $userID, $setID, $versionID) = shift->checkArgs(\@_, qw/user_id set_id version_id/);
	my $where = [ user_id_eq_set_id_eq_version_id_eq => $userID, $setID, $versionID ];
	if (wantarray) {
		return map {@$_} $self->{problem_version}->get_fields_where(["problem_id"], $where);
	} else {
		return $self->{problem_version}->count_where($where);
	}
}

# this code returns a list of all problem versions with the given userID,
# setID, and problemID, but that is (darn well ought to be) the same as
# listSetVersions, so it's not so useful as all that; c.f. above.
# sub listProblemVersions {
# 	my ($self, $userID, $setID, $problemID) = shift->checkArgs(\@_, qw/user_id set_id problem_id/);
# 	my $where = [user_id_eq_set_id_eq_problem_id_eq => $userID,$setID,$problemID];
# 	if (wantarray) {
# 		return grep { @$_ } $self->{problem_version}->get_fields_where(["version_id"], $where);
# 	} else {
# 		return $self->{problem_version}->count_where($where);
# 	}
# }

# versioned analog of existsUserProblem
sub existsProblemVersion {
	my ($self, $userID, $setID, $versionID, $problemID) =
		shift->checkArgs(\@_, qw/user_id set_id version_id problem_id/);
	return $self->{problem_version}->exists($userID, $setID, $versionID, $problemID);
}

# versioned analog of getUserProblem
sub getProblemVersion {
	my ($self, $userID, $setID, $versionID, $problemID) =
		shift->checkArgs(\@_, qw/user_id set_id version_id problem_id/);
	return ($self->getProblemVersions([ $userID, $setID, $versionID, $problemID ]))[0];
}

# versioned analog of getUserProblems
sub getProblemVersions {
	my ($self, @problemVersionIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id version_id problem_id/);
	return $self->{problem_version}->gets(@problemVersionIDs);
}

# versioned analog of getAllUserProblems
sub getAllProblemVersions {
	my ($self, $userID, $setID, $versionID) = shift->checkArgs(\@_, qw/user_id set_id version_id/);
	my $where = [ user_id_eq_set_id_eq_version_id_eq => $userID, $setID, $versionID ];
	my $order = ["problem_id"];
	return $self->{problem_version_merged}->get_records_where($where, $order);
}

# versioned analog of addUserProblem
sub addProblemVersion {
	my ($self, $ProblemVersion) = shift->checkArgs(\@_, qw/REC:problem_version/);

	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addProblemVersion: set version '
			. $ProblemVersion->version_id
			. ' of set '
			. $ProblemVersion->set_id
			. ' not found for user '
			. $ProblemVersion->user_id)
		unless $self->{set_version}
		->exists($ProblemVersion->user_id, $ProblemVersion->set_id, $ProblemVersion->version_id);
	WeBWorK::DB::Ex::DependencyNotFound->throw(error => 'addProblemVersion: problem '
			. $ProblemVersion->problem_id
			. ' of set '
			. $ProblemVersion->set_id
			. ' not found for user ')
		unless $self->{problem_user}
		->exists($ProblemVersion->user_id, $ProblemVersion->set_id, $ProblemVersion->problem_id);

	return $self->{problem_version}->add($ProblemVersion);
}

# versioned analog of putUserProblem
sub putProblemVersion {
	my ($self, $ProblemVersion) = shift->checkArgs(\@_, qw/REC:problem_version/);
	my $rows = $self->{problem_version}->put($ProblemVersion);    # DBI returns 0E0 for 0.
	WeBWorK::DB::Ex::RecordNotFound->throw(
		error => 'putProblemVersion: problem version not found (perhaps you meant to use addProblemVersion?)')
		if $rows == 0;
	return $rows;
}

# versioned analog of deleteUserProblem
sub deleteProblemVersion {
	# userID, setID, versionID, and problemID can be undefined if being called from this package
	my $U = caller eq __PACKAGE__ ? "!" : "";
	my ($self, $userID, $setID, $versionID, $problemID) =
		shift->checkArgs(\@_, "user_id$U", "set_id$U", "version_id$U", "problem_id$U");
	return $self->{problem_version}->delete($userID, $setID, $versionID, $problemID);
}

################################################################################
# problem_version_merged functions (NEW)
################################################################################

BEGIN {
	*MergedProblemVersion = gen_schema_accessor("problem_version_merged");
	#*newMergedProblemVersion = gen_new("problem_version_merged");
	#*countMergedProblemVersionsWhere = gen_count_where("problem_version_merged");
	*existsMergedProblemVersionWhere = gen_exists_where("problem_version_merged");
	#*listMergedProblemVersionsWhere = gen_list_where("problem_version_merged");
	*getMergedProblemVersionsWhere = gen_get_records_where("problem_version_merged");
}

sub existsMergedProblemVersion {
	my ($self, $userID, $setID, $versionID, $problemID) =
		shift->checkArgs(\@_, qw/user_id set_id version_id problem_id/);
	return $self->{problem_version_merged}->exists($userID, $setID, $versionID, $problemID);
}

sub getMergedProblemVersion {
	my ($self, $userID, $setID, $versionID, $problemID) =
		shift->checkArgs(\@_, qw/user_id set_id version_id problem_id/);
	return ($self->getMergedProblemVersions([ $userID, $setID, $versionID, $problemID ]))[0];
}

sub getMergedProblemVersions {
	my ($self, @problemVersionIDs) = shift->checkArgsRefList(\@_, qw/user_id set_id version_id problem_id/);
	return $self->{problem_version_merged}->gets(@problemVersionIDs);
}

sub getAllMergedProblemVersions {
	my ($self, $userID, $setID, $versionID) = shift->checkArgs(\@_, qw/user_id set_id version_id/);
	my $where = [ user_id_eq_set_id_eq_version_id_eq => $userID, $setID, $versionID ];
	my $order = ["problem_id"];
	return $self->{problem_version_merged}->get_records_where($where, $order);
}

################################################################################
# utilities
################################################################################

sub check_user_id {    #  (valid characters are [-a-zA-Z0-9_.,@])
	my $value = shift;
	if ($value =~ m/^[-a-zA-Z0-9_.@]*,?(set_id:)?[-a-zA-Z0-9_.@]*(,g)?$/) {
		return 1;
	} else {
		croak "invalid characters in user_id field: '$value' (valid characters are [-a-zA-Z0-9_.,@])";
		return 0;
	}
}

# The (optional) second argument to checkKeyfields is to support versioned
# (gateway) sets, which may include commas in certain fields (in particular,
# set names (e.g., setDerivativeGateway,v1)).
sub checkKeyfields($;$) {
	my ($Record, $versioned) = @_;
	foreach my $keyfield ($Record->KEYFIELDS) {
		my $value     = $Record->$keyfield;
		my $fielddata = $Record->FIELD_DATA;
		return if ($fielddata->{$keyfield}{type} =~ /AUTO_INCREMENT/);

		croak "undefined '$keyfield' field"
			unless defined $value;
		croak "empty '$keyfield' field"
			unless $value ne "";

		validateKeyfieldValue($keyfield, $value, $versioned);

	}
}

sub validateKeyfieldValue {

	my ($keyfield, $value, $versioned) = @_;

	if ($keyfield eq "problem_id" || $keyfield eq 'problemID') {
		croak "invalid characters in '"
			. encode_entities($keyfield)
			. "' field: '"
			. encode_entities($value)
			. "' (valid characters are [0-9])"
			unless $value =~ m/^[0-9]*$/;
	} elsif ($versioned and $keyfield eq "set_id" || $keyfield eq 'setID') {
		croak "invalid characters in '"
			. encode_entities($keyfield)
			. "' field: '"
			. encode_entities($value)
			. "' (valid characters are [-a-zA-Z0-9_.,])"
			unless $value =~ m/^[-a-zA-Z0-9_.,]*$/;
		# } elsif ($versioned and $keyfield eq "user_id") {
	} elsif ($keyfield eq "user_id" || $keyfield eq 'userID') {
		check_user_id($value);    #  (valid characters are [-a-zA-Z0-9_.,]) see above.
	} elsif ($keyfield eq "ip_mask") {
		croak "invalid characters in '$keyfield' field: '$value' (valid characters are [-a-zA-Z0-9_.,])"
			unless $value =~ m/^[-a-fA-F0-9_.:\/]*$/;

	} else {
		croak "invalid characters in '"
			. encode_entities($keyfield)
			. "' field: '"
			. encode_entities($value)
			. "' (valid characters are [-a-zA-Z0-9_.])"
			unless $value =~ m/^[-a-zA-Z0-9_.]*$/;
	}

}

# checkArgs spec syntax:
#
# spec = list_item | item*
# list_item = item is_list
# is_list = "*"
# item = item_name undef_ok? optional?
# item_name = record_item | bare_item
# record_item = is_versioned? "REC:" table
# is_versioned = "V"
# table = \w+
# bare_item = \w+
# undef_ok = "!"
# optional = "?"
#
# [[V]REC:]foo[!][?][*]

sub checkArgs {
	my ($self, $args, @spec) = @_;

	my $is_list = @spec == 1 && $spec[0] =~ s/\*$//;
	my ($min_args, $max_args);
	if ($is_list) {
		$min_args = 0;
	} else {
		foreach my $i (0 .. $#spec) {
			#print "$i - $spec[$i]\n";
			if ($spec[$i] =~ s/\?$//) {
				#print "$i - matched\n";
				$min_args = $i unless defined $min_args;
			}
		}
		$min_args = @spec unless defined $min_args;
		$max_args = @spec;
	}

	if (@$args < $min_args or defined $max_args and @$args > $max_args) {
		if ($min_args == $max_args) {
			my $s = $min_args == 1 ? "" : "s";
			croak "requires $min_args argument$s";
		} elsif (defined $max_args) {
			croak "requires between $min_args and $max_args arguments";
		} else {
			my $s = $min_args == 1 ? "" : "s";
			croak "requires at least $min_args argument$s";
		}
	}

	my ($name, $versioned, $table);
	if ($is_list) {
		$name = $spec[0];
		($versioned, $table) = $name =~ /^(V?)REC:(.*)/;
	}

	foreach my $i (0 .. @$args - 1) {
		my $arg = $args->[$i];
		my $pos = $i + 1;

		unless ($is_list) {
			$name = $spec[$i];
			($versioned, $table) = $name =~ /^(V?)REC:(.*)/;
		}

		if (defined $table) {
			my $class = $self->{$table}{record};
			#print "arg=$arg class=$class\n";
			croak "argument $pos must be of type $class"
				unless defined $arg
				and ref $arg
				and $arg->isa($class);
			eval { checkKeyfields($arg, $versioned) };
			croak "argument $pos contains $@" if $@;
		} else {
			if ($name !~ /!$/) {
				croak "argument $pos must contain a $name"
					unless defined $arg;
			}
		}
	}

	return $self, @$args;
}

sub checkArgsRefList {
	my ($self, $items, @spec) = @_;
	foreach my $i (0 .. @$items - 1) {
		my $item = $items->[$i];
		my $pos  = $i + 1;
		croak "item $pos must be a reference to an array"
			unless UNIVERSAL::isa($item, "ARRAY");
		eval { $self->checkArgs($item, @spec) };
		croak "item $pos $@" if $@;
	}

	return $self, @$items;
}

1;
