use strict;
use Data::Dumper;
use Bio::KBase::Utilities::ScriptThing;
use Carp;

#
# This is a SAS Component
#

=head1 NAME

er-get-entity-Family

=head1 SYNOPSIS

er-get-entity-Family [-c N] [-a] [--fields field-list] < ids > table.with.fields.added

=head1 DESCRIPTION

The Kbase will support the maintenance of protein families
(as sets of Features with associated translations).  We are
initially only supporting the notion of a family as composed of
a set of isofunctional homologs.  That is, the families we
initially support should be thought of as containing
protein-encoding genes whose associated sequences all implement
the same function (we do understand that the notion of "function"
is somewhat ambiguous, so let us sweep this under the rug by
calling a functional role a "primitive concept").
We currently support families in which the members are
protein sequences as well. Identical protein sequences
as products of translating distinct genes may or may not
have identical functions.  This may be justified, since
in a very, very, very few cases identical proteins do, in
fact, have distinct functions.

Example:

    er-get-entity-Family -a < ids > table.with.fields.added

would read in a file of ids and add a column for each field in the entity.

The standard input should be a tab-separated table (i.e., each line
is a tab-separated set of fields).  Normally, the last field in each
line would contain the id. If some other column contains the id,
use

    -c N

where N is the column (from 1) that contains the id.

This is a pipe command. The input is taken from the standard input, and the
output is to the standard output.

=head2 Related entities

The Family entity has the following relationship links:

=over 4
    
=item HasMember Feature

=item HasProteinMember ProteinSequence

=item IsCoupledTo Family

=item IsCoupledWith Family

=item IsFamilyFor Role

=item IsRepresentedIn Genome


=back

=head1 COMMAND-LINE OPTIONS

Usage: er-get-entity-Family [arguments] < ids > table.with.fields.added

    -a		    Return all available fields.
    -c num          Select the identifier from column num.
    -i filename     Use filename rather than stdin for input.
    --fields list   Choose a set of fields to return. List is a comma-separated list of strings.
    -a		    Return all available fields.
    --show-fields   List the available fields.

The following fields are available:

=over 4    

=item type

type of protein family (e.g. FIGfam, equivalog)

=item release

release number / subtype of protein family

=item family_function

optional free-form description of the family. For function-based families, this would be the functional role for the family members.

=item alignment

FASTA-formatted alignment of the family's protein sequences


=back

=head1 AUTHORS

L<The SEED Project|http://www.theseed.org>

=cut


our $usage = <<'END';
Usage: er-get-entity-Family [arguments] < ids > table.with.fields.added

    -c num          Select the identifier from column num
    -i filename     Use filename rather than stdin for input
    --fields list   Choose a set of fields to return. List is a comma-separated list of strings.
    -a		    Return all available fields.
    --show-fields   List the available fields.

The following fields are available:

    type
        type of protein family (e.g. FIGfam, equivalog)
    release
        release number / subtype of protein family
    family_function
        optional free-form description of the family. For function-based families, this would be the functional role for the family members.
    alignment
        FASTA-formatted alignment of the family's protein sequences
END



use Bio::KBase::CDMI::CDMIClient;
use Getopt::Long;

#Default fields

my @all_fields = ( 'type', 'release', 'family_function', 'alignment' );
my %all_fields = map { $_ => 1 } @all_fields;

my $column;
my $a;
my $f;
my $i = "-";
my @fields;
my $help;
my $show_fields;
my $geO = Bio::KBase::CDMI::CDMIClient->new_get_entity_for_script('c=i'		 => \$column,
								  "all-fields|a" => \$a,
								  "help|h"	 => \$help,
								  "show-fields"	 => \$show_fields,
								  "fields=s"	 => \$f,
								  'i=s'		 => \$i);
if ($help)
{
    print $usage;
    exit 0;
}

if ($show_fields)
{
    print STDERR "Available fields:\n";
    print STDERR "\t$_\n" foreach @all_fields;
    exit 0;
}

if ($a && $f) 
{
    print STDERR "Only one of the -a and --fields options may be specified\n";
    exit 1;
} 
if ($a)
{
    @fields = @all_fields;
}
elsif ($f) {
    my @err;
    for my $field (split(",", $f))
    {
	if (!$all_fields{$field})
	{
	    push(@err, $field);
	}
	else
	{
	    push(@fields, $field);
	}
    }
    if (@err)
    {
	print STDERR "er-get-entity-Family: unknown fields @err. Valid fields are: @all_fields\n";
	exit 1;
    }
} else {
    print STDERR $usage;
    exit 1;
}

my $ih;
if ($i eq '-')
{
    $ih = \*STDIN;
}
else
{
    open($ih, "<", $i) or die "Cannot open input file $i: $!\n";
}

while (my @tuples = Bio::KBase::Utilities::ScriptThing::GetBatch($ih, undef, $column)) {
    my @h = map { $_->[0] } @tuples;
    my $h = $geO->get_entity_Family(\@h, \@fields);
    for my $tuple (@tuples) {
        my @values;
        my ($id, $line) = @$tuple;
        my $v = $h->{$id};
	if (! defined($v))
	{
	    #nothing found for this id
	    print STDERR $line,"\n";
     	} else {
	    foreach $_ (@fields) {
		my $val = $v->{$_};
		push (@values, ref($val) eq 'ARRAY' ? join(",", @$val) : $val);
	    }
	    my $tail = join("\t", @values);
	    print "$line\t$tail\n";
        }
    }
}
__DATA__