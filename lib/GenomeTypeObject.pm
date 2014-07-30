# -*- perl -*-

package GenomeTypeObject;

#
# This is a SAS component.
#

########################################################################
# Copyright (c) 2003-2013 University of Chicago and Fellowship
# for Interpretations of Genomes. All Rights Reserved.
#
# This file is part of the SEED Toolkit.
#
# The SEED Toolkit is free software. You can redistribute
# it and/or modify it under the terms of the SEED Toolkit
# Public License.
#
# You should have received a copy of the SEED Toolkit Public License
# along with this program; if not write to the University of Chicago
# at info@ci.uchicago.edu or the Fellowship for Interpretation of
# Genomes at veronika@thefig.info or download a copy from
# http://www.theseed.org/LICENSE.TXT.
########################################################################

=head1 NAME

GenomeTypeObject - a helper class for manipulating GenomeAnnotation service genome objects.

=head1 SYNOPSIS

  $obj = GenomeTypeObject->new()

  $obj = GenomeTypeObject->initialize($raw_genome_object)
 
=head1 DESCRIPTION

The C<GenomeTypeObject> class wraps a number of common operations to be performed
against the genome object as defined in the KBase GenomeAnnotation service.

To use the methods here it is sufficient to just bless the JSON object containing
the genome data into the GenomeTypeObject class, but it is more efficient to initialize
it using the initialize method:

  $obj = GenomeTypeObject->initialize($raw_json)

Doing this will create internal indexes on the feature and contig data structures
to accelerate access to individual data items.

Before using the genome object as a raw JSON object again, however, you must invoke
the C<prepare_for_return()> method which strips these indexes out of the data object.

=cut


use strict;
use warnings;
use Data::Dumper;
use SeedUtils;
use File::Temp;
use File::Slurp;
use JSON::XS;
use gjoseqlib;
use Time::HiRes 'gettimeofday';
use IDclient;
use BasicLocation;
use IO::Handle;

our $have_unbless;
eval {
    require Data::Structure::Util;
    Data::Structure::Util->import('unbless');
    $have_unbless = 1;
};
use base 'Class::Accessor';

our $have_UUID;
our $have_Data_UUID;
eval {
    require UUID;
    $have_UUID = 1;
};
eval {
    require Data::UUID;
    $have_Data_UUID = 1;
};

__PACKAGE__->mk_accessors(qw(id_client));

=head2 $obj = GenomeTypeObject->new()

Create a new empty genome object.

=cut

sub new
{
    my($class) = @_;

    my $self = {
	contigs => [],
	features => [],
	close_genomes => [],
	analysis_events => []
    };
    bless $self, $class;

    $self->setup_id_allocation();
    return $self;
}

=head2 $obj = GenomeTypeObject->create_from_file($filename)

Load the given file, assumed to contain the JSON form of a genome object, and
return as a GenomeTypeObject instance.

The resulting object has not had the C<initialize> method invoked on it.

=cut

sub create_from_file
{
    my($class, $file) = @_;
    my $txt = read_file($file);
    my $self = decode_json($txt);
    return bless $self, $class;
}

=head2 $obj->set_metadata({ ... });

Set the metadata fields on this genome object based on a metadata
object as defined in the GenomeAnnotation typespec:

 typedef structure
 {
  genome_id id;
  string scientific_name;
  string domain;
  int genetic_code;
  string source;
  string source_id;
 } genome_metadata

=cut
    
sub set_metadata
{
    my($self, $meta) = @_;

    my @keys = qw(id scientific_name domain genetic_code source source_id taxonomy);
    for my $k (@keys)
    {
	if (exists($meta->{$k}))
	{
	    $self->{$k} = $meta->{$k};
	}
    }
    return $self;
}

sub initialize
{
    my($class, $self) = @_;

    $self = $class->initialize_without_indexes($self);
    $self->update_indexes();

    return $self;
}

sub initialize_without_indexes
{
    my($class, $self) = @_;

    bless $self, $class;

    $self->setup_id_allocation();

    return $self;
}

sub setup_id_allocation
{
    my($self) = @_;
    $self->{_id_client} = IDclient->new($self);
    return $self;
}

sub prepare_for_return
{
    my($self) = @_;

    delete $self->{$_} foreach  grep { /^_/ } keys %$self;

    #
    # There are still some invocations of &GenomeTypeObject::prepare_for_return(obj)
    #
    if (ref($self) && ref($self) ne 'HASH')
    {
	if ($have_unbless)
	{
	    unbless $self;
	    return $self;
	}
	else
	{
	    return { %$self };
	}
    }
    else
    {
	return $self;
    }
}

sub hostname
{
    my($self) = @_;

    return $self->{hostname} if $self->{hostname};
    $self->{hostname} = `hostname`;
    chomp $self->{hostname};
    return $self->{hostname};
}

sub update_indexes
{
    my($self) = @_;

    #
    # Create feature index.
    #

    my $feature_index = {};
    $self->{_feature_index} = $feature_index;
    for my $feature ($self->features)
    {
	$feature_index->{$feature->{id}} = $feature;
    }

    #
    # Create contig index.
    #
    my $contig_index = {};
    $self->{_contig_index} = $contig_index;
    for my $contig ($self->contigs)
    {
	$contig_index->{$contig->{id}} = $contig;
    }
    
    return $self;
}

sub features
{
    my($self) = @_;
    return @{$self->{features}};
}

sub contigs
{
    my($self) = @_;
    return @{$self->{contigs}};
}

=head2 $obj->add_contigs($contigs)

Add the given set of contigs to this genome object. C<$contigs> is a list of contig
objects, which we add to the genome object without further inspection.

=cut

sub add_contigs
{
    my($self, $contigs) = @_;
    push(@{$self->{contigs}}, @$contigs);
}

=head2 $obj->add_features_from_list($features)

Add the given features to the genome. Features here are instances of the compact_tuple type:

 typedef tuple <string id, string location, string feature_type, string function, string aliases> compact_feature;

used in the importation of features from an external source via a tab-separated text file.

We create an event for this import so that the source of the features so added is tracked.

Returns a hash mapping from the feature ID in the list to the allocated feature ID.

=cut

sub add_features_from_list
{
    my($self, $features) = @_;

    my $event = {
	tool_name => "add_features_from_list",
	execution_time => scalar gettimeofday,
	parameters => [],
	hostname => $self->hostname,
    };
    my $event_id = $self->add_analysis_event($event);

    my $map = {};
    
    for my $f (@$features)
    {
	my($id, $loc_str, $type, $func, $aliases_str) = @$f;

	my @aliases = split(/,/, $aliases_str);
	my @locs = map { my $l = BasicLocation->new($_);
		         [ $l->Contig, $l->Begin, $l->Dir, $l->Length ] } split(/,/, $loc_str);
	my $new_id = $self->add_feature({
	    -type => $type,
	    -location => \@locs,
	    -function => $func,
	    -aliases => \@aliases,
	    -analysis_event_d => $event_id,
	});
	$map->{$id} = $new_id;
    }
    return $map;
}

=head2 $obj->add_feature($params)

Add a new feature. The details of the feature are defined in the parameters hash. It has the following
keys:

=over 4

=item -id

Identifier for this feature. If not provided, a new identifier will be
created based on the genome id, the type of the feature and the current largest identifier for
that feature type.

=cut

sub add_feature {
    my ($self, $parms) = @_;
    my $genomeTO = $self;
    print STDERR (Dumper($parms), qq(\n\n)) if $ENV{DEBUG};
    
    my $id = $parms->{-id};
    my $id_client   = $parms->{-id_client};
    my $id_prefix   = $parms->{-id_prefix};
    my $type        = $parms->{-type}       or die "No feature-type -type";
    my $location    = $parms->{-location}   or die "No feature location -location";
    my $function    = $parms->{-function};
    my $annotator   = $parms->{-annotator}  || q(Nobody);
    my $annotation  = $parms->{-annotation} || q(Add feature);
    my $translation = $parms->{-protein_translation};
    my $event_id    = $parms->{-analysis_event_id};
    my $quality     = $parms->{-quality_measure};
    my $aliases     = $parms->{-aliases};

    if (!defined($id))
    {
	if (!defined($id_prefix))
	{
	    $id_prefix = $self->{id};
	}
	if (!defined($id_client))
	{
	    $id_client = $self->{_id_client};
	}
	my $typed_prefix = "$id_prefix.$type";
	my $next_num     = $id_client->allocate_id_range($typed_prefix, 1);
	# print STDERR Dumper($typed_prefix, $next_num);
	
	if (defined($next_num)) {
	    print STDERR "Allocated id for typed-prefix \'$typed_prefix\' starting from $next_num\n" if $ENV{DEGUG};
	}
	else {
	    die "Could not get a new ID with typed-prefix \"$typed_prefix\"" unless $next_num;
	}
	$id = join(".", $typed_prefix, $next_num);
    }    
    
    if (not defined $genomeTO->{features}) {
	$genomeTO->{features} = [];
    }
    my $features  = $genomeTO->{features};
    
    my $feature =  { id   => $id,
		     type => $type,
		     location => $location,
		     annotations => [[ $annotation, 
				       $annotator,
				       time(),
				       ]],
    };

    $feature->{quality} = $quality if $quality;
    $feature->{feature_creation_event} = $event_id if $event_id;
    $feature->{aliases} = $aliases if $aliases;

    if ($function) {
	$feature->{function} = $function;
	push @ { $feature->{annotations} }, [ "Set function to $function",
					      $annotator,
					      time(),
	                                      ];
    }
    
    if ($translation) {
	$feature->{protein_translation} = $translation;
    }
    
    push @$features, $feature;
    
    return $feature;
}

sub write_protein_translations_to_file
{
    my($self, $filename) = @_;

    my $fh;
    open($fh, ">", $filename) or die "Cannot write $filename: $!";

    for my $feature (@{$self->{features}})
    {
	my $trans = $feature->{protein_translation};
	if ($trans)
	{
	    write_fasta($fh, [$feature->{id}, undef, $trans]);
	}
    }
    close($fh);
}

sub write_feature_locations_to_file
{
    my($self, $filename, @feature_types) = @_;

    my %feature_types = map { $_ => 1 } @feature_types;

    my $fh;
    open($fh, ">", $filename) or die "Cannot write $filename: $!";

    for my $feature (@{$self->{features}})
    {
	next if (@feature_types && !$feature_types{$feature->{type}});

	my $loc = $feature->{location};
	my $loc_str = join(",", map { my $b = BasicLocation->new(@$_); $b->String() } @$loc);
	print $fh "$feature->{id}\t$loc_str\n";
    }
    close($fh);
}

#
# $filter is an optional parameter that is a code ref.
# It is invoked for each feature; only those features that
# have a translation and for which the filter returns true are written.
#
sub extract_protein_sequences_to_temp_file
{
    my($self, $filter) = @_;

    my($fh, $fn) = tmpnam();

    for my $feature (@{$self->{features}})
    {
	my $trans = $feature->{protein_translation};
	if (ref($filter))
	{
	    if ($filter->($feature))
	    {
		print STDERR "keeping $feature->{id} $feature->{function}\n";
	    }
	    else
	    {
		print STDERR "skippinging $feature->{id} $feature->{function}\n";
		next;
	    }
	}
	if ($trans)
	{
	    write_fasta($fh, [$feature->{id}, undef, $trans]);
	}
    }
    close($fh);
    return $fn;
}

sub extract_contig_sequences_to_temp_file
{
    my($self) = @_;

    my($fh, $fn) = tmpnam();

    for my $ctg (@{$self->{contigs}})
    {
	write_fasta($fh, [$ctg->{id}, undef, $ctg->{dna}]);
    }
    close($fh);
    return $fn;
}

sub write_temp_seed_dir
{
    my($self, $options) = @_;

    my $tmp = File::Temp->newdir(undef, CLEANUP => 1);

    $self->write_seed_dir($tmp, $options);
    return $tmp;
}

sub write_seed_dir
{
    my($self, $dir, $options) = @_;

    open(my $ctg_fh, ">", "$dir/contigs") or die "Cannot create $dir/contigs: $!";
    for my $contig (@{$self->{contigs}})
    {
	write_fasta($ctg_fh, [$contig->{id}, undef, $contig->{dna}]);
    }
    close($ctg_fh);

    #
    # Some individual file metadata.
    #
    my $write_md = sub { my($name, $value) = @_;
			 my $fh;
			 open($fh, ">", "$dir/$name") or die "Cannot open $dir/$name: $!";
			 print $fh "$value\n";
			 close($fh);
		    };
    $write_md->("GENETIC_CODE", $self->{genetic_code});
    $write_md->("GENOME", $self->{scientific_name});
    $write_md->("TAXONOMY", $self->{taxonomy}) if $self->{taxonomy};

    my $features = $self->{features};
    my %types = map { $_->{type} => 1 } @$features;

    my %typemap;
    if ($options->{map_CDS_to_peg})
    {
	delete $types{CDS};
	$types{peg} = 1;
    }
    my @types = keys %types;
    $typemap{$_} = $_ foreach @types;
    $typemap{CDS} = 'peg' if $options->{map_CDS_to_peg};
    print Dumper(\@types, \%typemap);

    #
    # closest.genomes file.
    #

    my $close = $self->{close_genomes};
    if (ref($close) && @$close)
    {
	open(my $close_fh, ">", "$dir/closest.genomes") or die "cannot open $dir/closest.genomes: $!";
	for my $c (@$close)
	{
	    print $close_fh join("\t", $c->{genome_id}, $c->{closeness_measure}, $c->{genome_name}), "\n";
	}
	close($close_fh);
    }

    my $fn_file = $options->{assigned_functions_file};
    $fn_file = "assigned_functions" if !$fn_file;
			      
    open(my $func_fh, ">", "$dir/$fn_file") or die "Cannot create $dir/fn_file: $!";
    open(my $anno_fh, ">", "$dir/annotations") or die "Cannot create $dir/annotations: $!";

    mkdir("$dir/Features");
    
    my(%tbl_fh, %fasta_fh);
	
    for my $type (@types)
    {
	my $tdir = "$dir/Features/$type";
	-d $tdir or mkdir($tdir) or die "Cannot mkdir $tdir: $!";
	
	my $fh;
	open($fh, ">", "$tdir/tbl") or die "Cannot create $dir/tbl:$ !";
	$tbl_fh{$type} = $fh;

	my $fafh;
	open($fafh, ">", "$tdir/fasta") or die "Cannot create $dir/fasta:$ !";
	$fasta_fh{$type} = $fafh;
    }

    #     "location" : [
    #        [
    #           "kb|g.140.c.0",
    #           "631472",
    #           "+",
    #           3216
    #        ]
    #     ],
    
    for my $feature (@$features)
    {
	my $fid = $feature->{id};
	my $type = $feature->{type};
	my @aliases;
	
	if ($options->{correct_fig_id} && $fid =~ /^\d+\.\d+\.$type/)
	{
	    $fid = "fig|$fid";
	}
	if ($type eq 'CDS' && $options->{map_CDS_to_peg})
	{
	    $type = 'peg';
	    $fid =~ s/\.CDS\./.peg./;
	}
	my $function = $feature->{function} || "hypothetical protein";
	print $func_fh "$fid\t$function\n";

	my $loc = $feature->{location};
	
	my @bloc;
	for my $loc_part (@$loc)
	{
	    my($ctg, $start, $strand, $len) = @$loc_part;
	    my $bl = BasicLocation->new($ctg, $start, $strand, $len);
	    push(@bloc, $bl);
	}
	my $sloc = join(",", map { $_->SeedString() } @bloc);

	print { $tbl_fh{$type} } join("\t", $fid, $sloc, @aliases), "\n";

	if ($feature->{protein_translation})
	{
	    write_fasta($fasta_fh{$type}, [$fid, undef, $feature->{protein_translation}]);
	}
	else
	{
	    write_fasta($fasta_fh{$type}, [$fid, undef, $self->get_feature_dna($feature->{id})]);
	}

	# typedef tuple<string comment, string annotator, int annotation_time, analysis_event_id> annotation;
	
	for my $anno (@{$feature->{annotations}})
	{
	    my($txt, $annotator, $time, $event_id) = @$anno;
	    print $anno_fh join("\n", $fid, $time, $annotator, $txt);
	    print $anno_fh "\n" if substr($txt, -1) ne "\n";
	    print $anno_fh "//\n";
	}
	    
    }

    for my $type (@types)
    {
	$fasta_fh{$type}->close();
	$tbl_fh{$type}->close();
    }
    close($anno_fh);
    close($func_fh);
}

sub add_analysis_event
{
    my($self, $event) = @_;

    if (ref($event) ne 'HASH')
    {
	die "GenomeTypeObject::add_analysis_event: event must be a hash reference";
    }

    my $uuid_str = create_uuid();

    $event->{id} = $uuid_str;

    push(@{$self->{analysis_events}}, $event);
    return $uuid_str;
}

sub update_function
{
    my($self, $user, $fid, $function, $event_id) = @_;

    my $feature = $self->find_feature($fid);

    my $annotation = ["Function updated to $function", $user, scalar gettimeofday, $event_id];
    # print STDERR Dumper($fid, $feature, $annotation);
    
    push(@{$feature->{annotations}}, $annotation);
    $feature->{function} = $function;
}

sub find_feature
{
    my($self, $fid) = @_;

    return $self->{_feature_index}->{$fid};
}

sub find_contig
{
    my($self, $contig) = @_;

    return $self->{_contig_index}->{$contig};
}

sub get_feature_dna
{
    my($self, $feature) = @_;

    my @seq;

    if (!ref($feature))
    {
	$feature = $self->find_feature($feature);
    }

    foreach my $loc (@{$feature->{location}})
    {
	my($contig, $beg, $strand, $len) = @$loc;

	my $cobj = $self->find_contig($contig);
	
	if ($strand eq '+' || $len == 1)
	{
	    
	    push(@seq, substr($cobj->{dna}, $beg - 1, $len));
	}
	else
	{
	    push(@seq, &SeedUtils::reverse_comp(substr($cobj->{dna}, $beg - $len, $len)));
	}
    }
    return join("", @seq);

}

sub create_uuid
{
    if ($have_UUID)
    {
	my($uuid, $uuid_str);
	UUID::generate($uuid);
	UUID::unparse($uuid, $uuid_str);
	return $uuid_str;
    }
    elsif ($have_Data_UUID)
    {
	return Data::UUID->new->create_str();
    }
    else
    {
	die "No UUID generator found";
    }
}

    
1;
