#!/usr/bin/perl
#======================================================================
# process_data.pl
#======================================================================
use strict;
use Data::Dumper;
use Benchmark;
use Getopt::Std;
use POSIX qw/strftime/;
use File::Basename;
use Text::CSV;
use DBD::SQLite;
use P3DataAPI;

use Bio::BVBRC::CEIRR::Config;

sub usage{
  my $str = <<STR;
Usage: process_data.pl -f file -t type[human,animal,serology,viral] -u user_file
STR

  print STDERR $str;
}

my $para;
my %options;
my $original_file = '';
my $file = '';
my $type = '';
my $delimiter = ',';

getopts("f:t:u:",\%options);
if ( !defined $options{t} && !defined $options{i}){
  usage();
  exit(1);
} else{
  $file = $options{f};
  $type = $options{t};
  $original_file = $options{u}; #original user file to add file name in additional metadata
}

my $cdate = strftime('%Y-%m-%d',localtime);
$para = new Bio::BVBRC::CEIRR::Config;
$para->setType($type);

my $jobDir = dirname($file);

my $brc_acc_file     = "BVBRC_Accession_ID.csv";

my %header     = $para->getFileHeader($type);
my %datasource = $para->getDataSourceCode();
my %country    = $para->getCountryCode();

my $seq = $para->getSequence();

my $api = P3DataAPI->new;

# define csv parser object
my $csv = Text::CSV->new({ sep_char => $delimiter, eol => $/});

my @data;
open(FH, '<', "$file") or die "Failed to open $file: $!"; 
while( my $line = <FH> ){
  chomp $line;

  if ($csv->parse($line)) {
    my @lines = $csv->fields();
    push (@data, \@lines);   
  } else {
    print STDERR "WARNING: Line could not be parsed: $line\n";
  }
}
close FH;

my $row_size = scalar @data;
my $col_size = scalar @{$data[0]};
my @headers;
for (my $h = 0; $h < $col_size; $h++){
  push @headers, lc $data[0][$h];
}

my %hash_data; 
for( my $i = 0; $i < $row_size; $i++ ){
  for( my $j = 0; $j < $col_size; $j++ ){
    $hash_data{$headers[$j]}->{$i} = $data[$i][$j];
  } 
}

# create bvbrc accession file header
my $accession_info = "";
if( $type =~ /human/ or $type eq "animal" ){
  $accession_info .= "Row,Sample_Identifier,Influenza_Test_Type,BVBRC_Accession_ID\n";
}else{
  $accession_info .= "Row,Sample_Identifier,Influenza_Test_Type,BVBRC_Accession_ID,Virus_Identifier\n";
}
$para->write_to_file($brc_acc_file ,"$accession_info", "new");

# temp file for solr 
my $temp_file = "sample_processed.csv";
open(my $processed_file, ">", $temp_file) or die "Failed to open $temp_file: $!";

my @new_header = @headers;
push(@new_header, ("Create_Date", "File_Name"));

if($type =~ /human/){
  push(@new_header, ("Host_Group", "BV_Accession", "Collection_Date", "TAXON_ID", "Influenza_Type", "Taxon_Lineage_IDs"));
}elsif($type eq "animal"){
  push(@new_header, ("Host_Group", "BV_Accession", "TAXON_ID", "Influenza_Type", "Taxon_Lineage_IDs"));
}else{
  push(@new_header, ("Source_Type", "BV_Accession", "Host_Group", "Host_Identifier", "Host_Age", "Host_Common_Name", "Host_Health", "Host_Sex", "Host_Species", "Influenza_Type", "Collection_City", "Collection_State", "Collection_Country", "Collection_Date"));
}

$csv->print($processed_file, \@new_header);
my $last_row_number = 1;
my %taxon_id_map;
my %taxon_lineage_map;
for( my $s = 1; $s < $row_size; $s++ ){
  my @lines = @{$data[$s]};

  my $dcode = $hash_data{'contributing_institution'}->{$s};
  my $species = $hash_data{'host_species'}->{$s};
  my $taxon_id = getTaxonIDByName($species);
  my $sample_id = $hash_data{'sample_identifier'}->{$s};
 
  my $strain  =  uc $hash_data{'strain_name'}->{$s};
  my $subtype =  uc $hash_data{'influenza_subtype'}->{$s};

  my $ftype = "Influenza virus";
  if($strain){
    if($strain eq "FLU A" || $strain =~ /^A[\/w+]/){
      $ftype = "Influenza A virus"; 
    }elsif($strain eq "FLU B" || $strain =~ /^B[\/w+]/){
      $ftype = "Influenza B virus";
    }elsif($strain eq "FLU C" || $strain =~ /^C[\/w+]/){
      $ftype = "Influenza C virus";
    }elsif($strain eq "FLU D" || $strain =~ /^D[\/w+]/){
      $ftype = "Influenza D virus";
    }elsif($strain =~ /^HRV-/){
      $ftype = "Rhinovirus";
    }elsif($strain =~ /^DENV-/){
      $ftype = "Dengue virus";
    }elsif($strain =~ /^Ebola/){
      $ftype = "Ebola virus";
    }elsif($strain =~ /^HPIV3/){
      $ftype = "Human parainfluenza virus 3";
    }elsif($strain =~ /^HMPV/){
      $ftype = "Human Metapneumovirus";
    }elsif($strain =~ /^RSV/){
      $ftype = "Human respiratory syncytial virus";
      $ftype = "Human respiratory syncytial virus A" if($strain =~ /^RSVA/);
      $ftype = "Human respiratory syncytial virus B" if($strain =~ /^RSVB/);
    }
    if(!$taxon_id){
      my $taxstring;
      if($strain =~ /^[A|B|C|D][\/w+]/){
        if($subtype){
          $taxstring = "$ftype ($strain($subtype))";
        }else{
          $taxstring = "$ftype ($strain)";
        }
      }elsif($strain =~ /^HRV-/){
        $subtype =~ s/A0/A/;
        $subtype =~ s/B0/B/;
        $subtype =~ s/C0/C/;
        $taxstring = "$ftype $subtype";
        #$ftype = "$ftype $subtype"; 
      }elsif($strain =~ /^DENV-/){
        $taxstring = "$ftype $subtype";
        #$ftype = "$ftype $subtype";
      }else{
        $taxstring = $ftype;
      }
      $taxstring =~ s/\s+$//;
      $taxon_id = getTaxonIDByName("$taxstring");
      if ( !$taxon_id ){
        #deal with not existing taxon_id like Rhinovirus A35
        $taxstring =~ /(\w+)\s(\w+)?/;
        $taxon_id = getTaxonIDByName($1);
      }
    }
  } 
  if(!$taxon_id){
    my $taxstring = $ftype;
    $taxon_id = getTaxonIDByName($taxstring);
  }
  my $taxidlineage  = getTaxonLineageById($taxon_id);

  my $tt = $hash_data{'influenza_test_type'}->{$s};
  my @tts = split (',', $tt);
  my $tr = $hash_data{'influenza_test_result'}->{$s};
  my @trs = split (',', $tr);
  my $ti = $hash_data{'influenza_test_interpretation'}->{$s};
  my @tis = split (',', $ti);
  my $ps = $hash_data{'definition_of_positive_sample'}->{$s};
  my @pss= split (',',$ps);
  my $st = $hash_data{'influenza_subtype'}->{$s}; 
  my @sts= split (',',$st);

  my $j = 0;
  my $newval;
  foreach my $val (@lines){
    my $header_value = lc $headers[$j];

    my $nval = $val;
    if ( $header_value eq "contributing_institution" ) {
      my $source_name = $datasource{$dcode};
      $nval = $source_name if($source_name);
    } elsif ( $header_value eq "collection_country" ) {
      my $country_name = $country{name}->{lc $hash_data{'collection_country'}->{$s}};
      $nval = $country_name;
    } elsif ( $header_value eq "influenza_test_type") {
      $nval = "NA" if(!$val);
    } elsif ( $header_value eq "influenza_test_result") {
      $nval = "NA" if(!$val);
    } elsif ( $header_value eq "influenza_test_interpretation") {
      $nval = "NA" if(!$val);;
    } elsif ( $header_value eq "collection_date" || $header_value eq "collection_season" || $header_value eq "submission_date" || $header_value eq "embargo_end_date") {
      # convert ISO8601
      # ISO8601 format: 2018-10-25T00:00:00Z

      my $now = time();
      my $tz =  strftime("T%H:%M:%S", localtime($now))."Z";
      my %hash=( JAN => "01",
        FEB => "02",
        MAR => "03",
        APR => "04",
        MAY => "05",
        JUN => "06",
        JUL => "07",
        AUG => "08",
        SEP => "09",
        OCT => "10",
        NOV => "11",
        DEC => "12"
      );
      my $dday;
      my $dmon;
      my $dyy;
      if($val){
        $val =~ tr/\//-/;
        if($val =~ /^(\d{4})-(\d{2})-(\d{2})$/){  # val=yyyy-mm-dd
          $nval = $val.$tz;
        }elsif($val =~ /^(\d{2})-(\d{2})-(\d{2})$/){  # val=mm-dd-yy
          my @arr = split /-/, $val;
          $dmon = $arr[0];
          $dday = $arr[1];
          $dyy  = "20".$arr[2];
          $nval = "$dyy-$dmon-$dday$tz";
        }elsif($val =~ /^(\d{4})-(\d{2})$/ ){     # val=yyyy-mm
          $dday = "01";
          $nval = "$val-$dday$tz";
        }elsif($val =~ /^(\d{4})-(\d{4})$/ ){     # val=yyyy-yyyy
          my @arr = split /-/, $val;
          $dday = "01";
          $dmon = "01";
          $dyy  = $arr[0];
          $nval = "$dyy-$dmon-$dday$tz";
        }elsif($val =~ /^(\d{4})$/ ){    # val=yyyy
          $dday = "01";
          $dmon = "01";
          $dyy  = $val;
          $nval = "$dyy-$dmon-$dday$tz";
        }else{
          my @arr = split /-/, $val;
          my $arr_size = @arr;
          if( $arr_size == 3 ){     # val=10-Feb-2021 or 10-Feb-21
            my ($dd, $mon, $yy) = @{arr};
            $dday = $dd;
            $dmon = $hash{uc $mon};
            $dyy = $yy;
            if( $dyy =~ /^([0-9]{2})$/ ){
              $dyy = "20".$dyy;
            }
            $nval = "$dyy-$dmon-$dday$tz";
          }elsif( $arr_size == 2 ){     # val=Feb-2021 or Feb-21
            my ($mon, $yy) = @{arr};
            $dday = "01";
            $dmon = $hash{uc $mon};
            $dyy = $yy;
            if( $dyy =~ /^([0-9]{2})$/ ){
              $dyy = "20".$dyy;
            }
            $nval = "$dyy-$dmon-$dday$tz";
          }else{
            my ($yy) = @{arr};
            $dday = "01";
            $dmon = "01";
            $dyy = $yy;
            if( $dyy =~ /^([0-9]{2})$/ ){
              $dyy = "20".$dyy;
            }
            $nval = "$dyy-$dmon-$dday$tz";
          }
        }
      }else{
        $nval = "NULL";
      }
      # 2018-10-25T00:00:00Z
      if($nval !~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/){
        print STDERR "Invalid ISO8601 format of collection_date for $sample_id, $nval \n";
        $nval = "";
      }
      if($type =~ /human/ and $header_value eq "collection_season"){
        $hash_data{'collection_date'}->{$s} = $nval;
        $nval = $val;
      }
    }
    if ( $nval =~ /,/) {
      $newval .= '"'.$nval.'"'.$delimiter;
    } else {
      $newval .= $nval.$delimiter;
    }
    
    $j++;
  }

  chop $newval;

  my $size = @tts; 
  my @newlines;
  if ( $csv->parse($newval)) {
    @newlines = $csv->fields();
  } else {
    die "New line could not be parsed: $newval\n"
  }

  if($size){ 
    for(my $i = 0; $i < $size; $i++){
      my @new_line = ();
      my $j = 0;
      my $influenza_test_type_val;
      foreach my $nval (@newlines){
        my $header_name = lc $headers[$j];
        if ( $header_name eq "influenza_test_type"){
          $nval = $tts[$i];
          $influenza_test_type_val = $tts[$i];
        } elsif ( $header_name eq "influenza_test_result"){
          $nval = $trs[$i];
        } elsif ( $header_name eq "influenza_test_interpretation"){
          $nval = $tis[$i];
        } elsif ( $header_name eq "definition_of_positive_sample"){
          $nval = $pss[$i];
        } elsif ( $header_name eq "influenza_subtype"){
          $nval = $sts[$i];
        }
        #if ( $nval =~ /,/ and $nval !~ /^"/){
        #  $nval = '"'.$nval.'"';
        #}
        push(@new_line, ($nval));
        $j++;     
      }

      # Assign new accession id
      my $dcode = $hash_data{'contributing_institution'}->{$s};
      my $sampleid = $hash_data{'sample_identifier'}->{$s};
      my $virusid = $hash_data{'virus_identifier'}->{$s};
      $seq++;

      my $row_number = $hash_data{'row'}->{$s};

      my $bvbrc_accession_info = "";
      #print STDERR "BEFORE WHILE: $row_number,$last_row_number,$sampleid,ERROR: No accession id assigned.\n";
      #while ($last_row_number < $row_number) {
      #  $bvbrc_accession_info .= "$last_row_number,$sampleid,ERROR: No accession id assigned.\n";
      #  print STDERR "$last_row_number,$sampleid,ERROR: No accession id assigned.\n";
      #  $last_row_number++;
      #}
      my $seq_ext = sprintf("%010d", $seq);
      my $brc_acc = "BVBRC_".$dcode.$seq_ext;
      $hash_data{'bvbrc_accession'}->{$s} = $brc_acc;
      if( $type =~ /human/ or $type eq "animal" ){
        $bvbrc_accession_info .= "$row_number,$sampleid,$influenza_test_type_val,$brc_acc\n";
      }else{
        $bvbrc_accession_info .= "$row_number,$sampleid,$influenza_test_type_val,$brc_acc,$virusid\n";
      }
      $para->write_to_file($brc_acc_file,$bvbrc_accession_info);
      print STDERR "Assigning accession id $brc_acc to the sample $sampleid for row $row_number\n";
      $last_row_number++;
 
      #Push create date and file name for additional_metadata 
      my $file_name = basename($original_file);
      push(@new_line, ($cdate, $file_name));

      if($type =~ /human/){
        push(@new_line, ($type, $hash_data{'bvbrc_accession'}->{$s}, $hash_data{'collection_date'}->{$s}, $taxon_id, $ftype, $taxidlineage));
      }elsif($type eq "animal"){
        push(@new_line, ($type, $hash_data{'bvbrc_accession'}->{$s}, $taxon_id, $ftype, $taxidlineage));
      }else{
        #added Host_Group Host_Identifier Host_Age Host_Common_Name Host_Health Host_Sex Host_Species Influenza_Type Collection_City Collection_State  Collection_Country  Collection_Date
        my @res = $api->query('surveillance', ['eq', 'sample_identifier', $hash_data{'sample_identifier'}->{$s}]);
        my %surv;
        if(scalar @res > 0){
          my $res_obj = $res[0];
          while (my ($k, $v) = each %$res_obj){
            $surv{$k} = $v;
          }
        }else{
          print STDERR "No sample found for $hash_data{'sample_identifier'}->{$s}\n";
        }
        push(@new_line, ($type, $hash_data{'bvbrc_accession'}->{$s}, $surv{host_group}, $surv{host_identifier}, $surv{host_age}, $surv{host_common_name}, $surv{host_health}, $surv{host_sex}, $surv{host_species}, $surv{influenza_type}, $surv{collection_city}, $surv{collection_state}, $surv{collection_country}, $surv{collection_date}));
      }
      $csv->print($processed_file, \@new_line)
    }
  }
}
close $processed_file;
$para->setSequence($seq);
print STDERR "Finished $file processing.\n";

1;

sub getTaxonIDByName {
  my ($taxon_name) = @_;

  my $taxon_id;
  if ($taxon_name ne ''){
    if (exists $taxon_id_map{$taxon_name}){
      $taxon_id = $taxon_id_map{$taxon_name};
    }else{
      #Remove white space and paranthesis for solr
      $taxon_name =~ s/([()])| //g;
      my @res = $api->query('taxonomy', ['eq', 'taxon_name', $taxon_name], ['select', 'taxon_id,lineage_ids']);

      if (scalar @res != 0){
        $taxon_id = $res[0]->{taxon_id};
        my @lineage_ids = $res[0]->{lineage_ids};

        if (scalar @lineage_ids > 0){
          my $lineage_ids_str;
          foreach my $id ( @lineage_ids){
            $lineage_ids_str .= join " ", @$id;
          }
          $taxon_lineage_map{$taxon_id} = $lineage_ids_str;
        }
      }
   
      #Assign value even if empty to avoid query every time
      $taxon_id_map{$taxon_name} = $taxon_id;
    }
  }

  return $taxon_id;
}

sub getTaxonLineageById {
  my ($taxon_id) = @_;

  my $taxon_lineage_ids;
  if ($taxon_id ne ''){
    if (exists $taxon_lineage_map{$taxon_id}){
      $taxon_lineage_ids = $taxon_lineage_map{$taxon_id};
    }else{
      my @res = $api->query('taxonomy', ['eq', 'taxon_id', $taxon_id], ['select', 'lineage_ids']);

      if (scalar @res != 0){
        my @lineage_ids = $res[0]->{lineage_ids};
        my $lineage_ids_str;
        foreach my $id ( @lineage_ids){
          $lineage_ids_str .= join " ", @$id;
        }
        $taxon_lineage_ids = $lineage_ids_str;
      }

      #Assign value even if empty to avoid query every time
      $taxon_lineage_map{$taxon_id} = $taxon_lineage_ids;
    }
  }

  return $taxon_lineage_ids;
}